#!/usr/bin/env bash
set -Eeuo pipefail

SIEM='172.30.0.20'
AGENT_NAME='lab7-linux'
FIM_DIR='/home/vagrant/lab7-fim'

echo '=================================================='
echo 'CSA LAB 7 - ALMALINUX WAZUH ENDPOINT'
echo '=================================================='
date -Is

timedatectl set-timezone Europe/Brussels || true

echo
echo '=== ENDPOINT ==='
hostnamectl
ip -br address
ip route

echo
echo '=== SIEM CONNECTIVITY ==='

ping -c 2 "$SIEM"

timeout 5 bash -c "</dev/tcp/${SIEM}/1514"
echo 'TCP_1514_OK'

timeout 5 bash -c "</dev/tcp/${SIEM}/1515"
echo 'TCP_1515_OK'

echo
echo '=== WAZUH REPOSITORY ==='

rpm --import \
    https://packages.wazuh.com/key/GPG-KEY-WAZUH

cat >/etc/yum.repos.d/wazuh.repo <<'EOF'
[wazuh]
gpgcheck=1
gpgkey=https://packages.wazuh.com/key/GPG-KEY-WAZUH
enabled=1
name=Wazuh repository
baseurl=https://packages.wazuh.com/4.x/yum/
protect=1
EOF

dnf -y install \
    curl \
    jq \
    python3

echo
echo '=== WAZUH AGENT ==='

if ! rpm -q wazuh-agent >/dev/null 2>&1; then
    WAZUH_MANAGER="$SIEM" \
    WAZUH_AGENT_NAME="$AGENT_NAME" \
        dnf -y install wazuh-agent-4.14.7-1
else
    echo 'Wazuh agent already installed.'
fi

sed -i \
    "s#<address>[^<]*</address>#<address>${SIEM}</address>#" \
    /var/ossec/etc/ossec.conf

echo
echo '=== EXPLICIT AGENT ENROLLMENT ==='

if ! grep -Eq '^[0-9]{3,}[[:space:]]' \
    /var/ossec/etc/client.keys \
    2>/dev/null
then
    /var/ossec/bin/agent-auth \
        -m "$SIEM" \
        -A "$AGENT_NAME"
else
    echo 'Agent already has a registration key.'
fi

echo
echo '=== FIM DIRECTORY ==='

install \
    -d \
    -o vagrant \
    -g vagrant \
    -m 0755 \
    "$FIM_DIR"

echo
echo '=== CONFIGURE REALTIME FIM ==='

python3 <<'PY'
from pathlib import Path

p = Path("/var/ossec/etc/ossec.conf")
text = p.read_text()

path = "/home/vagrant/lab7-fim"

entry = (
    '    <directories realtime="yes" '
    'check_all="yes" report_changes="yes">'
    f'{path}</directories>'
)

if path not in text:
    marker = "  </syscheck>"

    if marker not in text:
        raise SystemExit(
            "Could not find </syscheck> in ossec.conf"
        )

    text = text.replace(
        marker,
        entry + "\n" + marker,
        1
    )

    p.write_text(text)

print("FIM_CONFIG_OK")
PY

echo
echo '=== VALIDATE CONFIG ==='

grep \
    -A4 \
    -B4 \
    '/home/vagrant/lab7-fim' \
    /var/ossec/etc/ossec.conf

echo
echo '=== START AGENT ==='

systemctl daemon-reload
systemctl enable wazuh-agent >/dev/null
systemctl restart wazuh-agent

sleep 10

systemctl is-active --quiet wazuh-agent

echo 'WAZUH_AGENT_ACTIVE'

echo
echo '=== AGENT LOG ==='

tail -n 60 \
    /var/ossec/logs/ossec.log

echo
echo '=== WAIT FOR FIM ==='

for _ in $(seq 1 30); do
    if grep -qi \
        'File integrity monitoring scan finished' \
        /var/ossec/logs/ossec.log
    then
        echo 'FIM_INITIAL_SCAN_FINISHED'
        break
    fi

    sleep 2
done

echo
echo '=== DISABLE AUTOMATIC REPOSITORY UPDATES ==='

sed -i \
    's/^enabled=1/enabled=0/' \
    /etc/yum.repos.d/wazuh.repo

echo
echo '=================================================='
echo 'LAB7_LINUX_ENDPOINT_READY'
echo '=================================================='
