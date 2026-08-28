#!/usr/bin/env bash
set -Eeuo pipefail

echo '=================================================='
echo 'CSA LAB 7 - LINUX THREAT HUNTING'
echo '=================================================='

echo
echo '=== AUDITD ==='

dnf -y install audit curl

systemctl enable auditd >/dev/null || true

if ! systemctl is-active --quiet auditd; then
    systemctl start auditd
fi

systemctl is-active auditd

echo
echo '=== ENSURE WAZUH READS AUDIT LOG ==='

python3 <<'PY'
from pathlib import Path

path = Path("/var/ossec/etc/ossec.conf")
text = path.read_text()

needle = "/var/log/audit/audit.log"

if needle not in text:
    block = """
  <localfile>
    <log_format>audit</log_format>
    <location>/var/log/audit/audit.log</location>
  </localfile>
"""

    pos = text.rfind("</ossec_config>")

    if pos == -1:
        raise SystemExit("Could not find closing ossec_config tag")

    text = text[:pos] + block + text[pos:]
    path.write_text(text)

print("AUDIT_LOG_COLLECTION_OK")
PY

echo
echo '=== PERSISTENT EXECVE RULE ==='

cat >/etc/audit/rules.d/99-wazuh-command-monitoring.rules <<'EOF'
-a always,exit -F arch=b64 -S execve -F auid=1000 -F auid!=4294967295 -k audit-wazuh-c
EOF

augenrules --load

echo
echo '=== ACTIVE AUDIT RULE ==='

auditctl -l |
    grep 'audit-wazuh-c'

echo
echo '=== RESTART WAZUH AGENT ==='

systemctl restart wazuh-agent
sleep 5

systemctl is-active wazuh-agent

echo
echo '=== VERIFY LOG COLLECTION ==='

grep \
    -A3 \
    -B2 \
    '/var/log/audit/audit.log' \
    /var/ossec/etc/ossec.conf ||
    true

echo
echo 'LINUX_THREAT_HUNTING_READY'
