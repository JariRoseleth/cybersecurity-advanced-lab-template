#!/usr/bin/env bash
set -euxo pipefail

export DEBIAN_FRONTEND=noninteractive

apt-get update

apt-get install -y \
  ca-certificates \
  curl \
  default-mysql-client \
  dnsutils \
  hydra \
  iproute2 \
  jq \
  net-tools \
  netcat-openbsd \
  nmap \
  openssh-client \
  openssh-server \
  python3 \
  tcpdump \
  traceroute \
  wget \
  whois

# Tijdelijk bewust zwakke labcredentials.
echo 'vagrant:vagrant' | chpasswd

install -d -m 0755 /etc/ssh/sshd_config.d

cat > /etc/ssh/sshd_config.d/00-csa-red.conf <<'EOF'
PasswordAuthentication yes
KbdInteractiveAuthentication no
PermitRootLogin no
EOF

systemctl enable ssh
systemctl restart ssh

# Dit script zoekt de interface op basis van het vaste MAC-adres.
# Het wordt gebruikt nadat de tijdelijke Vagrant-NAT-adapter verwijderd is.
cat > /usr/local/sbin/csa-red-network <<'EOF'
#!/bin/sh
set -eu

TARGET_MAC="08:00:27:62:10:10"
IFACE=""
ATTEMPT=0

while [ "$ATTEMPT" -lt 20 ]; do
    for SYSIF in /sys/class/net/*; do
        if [ -f "$SYSIF/address" ] &&
           [ "$(cat "$SYSIF/address")" = "$TARGET_MAC" ]; then
            IFACE="$(basename "$SYSIF")"
            break
        fi
    done

    [ -n "$IFACE" ] && break

    ATTEMPT=$((ATTEMPT + 1))
    sleep 1
done

if [ -z "$IFACE" ]; then
    echo "CSA host-onlyinterface met MAC $TARGET_MAC niet gevonden." >&2
    exit 1
fi

ip link set "$IFACE" up
ip address replace 192.168.62.10/24 dev "$IFACE"
ip route replace default via 192.168.62.254 dev "$IFACE"

rm -f /etc/resolv.conf
printf 'nameserver 192.168.62.254\n' > /etc/resolv.conf
EOF

chmod 0755 /usr/local/sbin/csa-red-network

cat > /etc/systemd/system/csa-red-network.service <<'EOF'
[Unit]
Description=Configure CSA red host-only network
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/csa-red-network
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable csa-red-network.service