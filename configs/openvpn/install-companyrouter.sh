#!/usr/bin/env bash
set -Eeuo pipefail

echo
echo '=================================================='
echo 'CSA LAB 9 - COMPANYROUTER'
echo '=================================================='

echo
echo '=== 1. NETWORK VALIDATION ==='

test "$(hostname)" = "companyrouter"

ip -4 addr show dev eth1 | grep -q '192\.168\.62\.253/'
ip -4 addr show dev eth2 | grep -q '172\.30\.255\.254/'

sysctl -w net.ipv4.ip_forward=1

cat >/etc/sysctl.d/90-csa-openvpn.conf <<'EOF'
net.ipv4.ip_forward = 1
EOF

echo
echo '=== 2. INSTALL OPENVPN + EASYRSA ==='

dnf -y install epel-release
dnf -y install openvpn easy-rsa

openvpn --version | head -n 3

echo
echo '=== 3. LOCATE EASYRSA ==='

EASYRSA_SOURCE="$(find /usr/share/easy-rsa \
    -type f \
    -name easyrsa \
    2>/dev/null |
    sort |
    tail -n 1)"

if [ -z "${EASYRSA_SOURCE}" ]; then
    echo 'ERROR: easyrsa niet gevonden.'
    exit 1
fi

echo "EasyRSA: ${EASYRSA_SOURCE}"

EASYRSA_SOURCE_DIR="$(dirname "${EASYRSA_SOURCE}")"

rm -rf /etc/openvpn/easy-rsa
mkdir -p /etc/openvpn/easy-rsa

cp -a "${EASYRSA_SOURCE_DIR}/." /etc/openvpn/easy-rsa/

cd /etc/openvpn/easy-rsa

chmod +x ./easyrsa

echo
echo '=== 4. BUILD PKI ==='

rm -rf pki

export EASYRSA_BATCH=1
export EASYRSA_REQ_CN='CSA-Lab9-CA'

./easyrsa init-pki
./easyrsa build-ca nopass

./easyrsa gen-req companyrouter nopass
./easyrsa sign-req server companyrouter

./easyrsa gen-req remote-employee nopass
./easyrsa sign-req client remote-employee

./easyrsa gen-dh
./easyrsa gen-crl

echo
echo '=== 5. SERVER CERTIFICATES ==='

mkdir -p /etc/openvpn/server

install -m 0644 pki/ca.crt \
    /etc/openvpn/server/ca.crt

install -m 0644 pki/issued/companyrouter.crt \
    /etc/openvpn/server/companyrouter.crt

install -m 0600 pki/private/companyrouter.key \
    /etc/openvpn/server/companyrouter.key

install -m 0644 pki/dh.pem \
    /etc/openvpn/server/dh.pem

install -m 0644 pki/crl.pem \
    /etc/openvpn/server/crl.pem

openvpn --genkey secret /etc/openvpn/server/ta.key
chmod 600 /etc/openvpn/server/ta.key

echo
echo '=== 6. SERVER CONFIG ==='

install -m 0644 \
    /home/vagrant/server.conf \
    /etc/openvpn/server/server.conf

echo
echo '=== 7. CERTIFICATE VALIDATION ==='

openssl x509 \
    -in /etc/openvpn/server/companyrouter.crt \
    -noout \
    -subject \
    -issuer \
    -dates \
    -ext extendedKeyUsage

openssl verify \
    -CAfile /etc/openvpn/server/ca.crt \
    /etc/openvpn/server/companyrouter.crt

openssl verify \
    -CAfile pki/ca.crt \
    pki/issued/remote-employee.crt

echo
echo '=== 8. FIREWALL INTEGRATION ==='

if ! nft list chain inet filter input >/dev/null 2>&1; then
    echo 'ERROR: nftables chain inet filter input ontbreekt.'
    exit 1
fi

if ! nft list chain inet filter forward >/dev/null 2>&1; then
    echo 'ERROR: nftables chain inet filter forward ontbreekt.'
    exit 1
fi

cat >/usr/local/sbin/csa-openvpn-firewall-apply <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

# Remove previous Lab-9 rules if they exist.
while nft -a list chain inet filter input 2>/dev/null |
      grep 'csa-lab9-openvpn-input' |
      grep -o 'handle [0-9]\+' |
      awk '{print $2}' |
      head -n1 |
      grep -q '[0-9]'; do

    HANDLE="$(
        nft -a list chain inet filter input |
        grep 'csa-lab9-openvpn-input' |
        grep -o 'handle [0-9]\+' |
        awk '{print $2}' |
        head -n1
    )"

    nft delete rule inet filter input handle "${HANDLE}"
done

while nft -a list chain inet filter forward 2>/dev/null |
      grep 'csa-lab9-openvpn-forward-out' |
      grep -o 'handle [0-9]\+' |
      awk '{print $2}' |
      head -n1 |
      grep -q '[0-9]'; do

    HANDLE="$(
        nft -a list chain inet filter forward |
        grep 'csa-lab9-openvpn-forward-out' |
        grep -o 'handle [0-9]\+' |
        awk '{print $2}' |
        head -n1
    )"

    nft delete rule inet filter forward handle "${HANDLE}"
done

while nft -a list chain inet filter forward 2>/dev/null |
      grep 'csa-lab9-openvpn-forward-return' |
      grep -o 'handle [0-9]\+' |
      awk '{print $2}' |
      head -n1 |
      grep -q '[0-9]'; do

    HANDLE="$(
        nft -a list chain inet filter forward |
        grep 'csa-lab9-openvpn-forward-return' |
        grep -o 'handle [0-9]\+' |
        awk '{print $2}' |
        head -n1
    )"

    nft delete rule inet filter forward handle "${HANDLE}"
done

# Permit only remote-employee to establish OpenVPN.
nft 'insert rule inet filter input iifname "eth1" ip saddr 172.10.10.123 udp dport 1194 counter accept comment "csa-lab9-openvpn-input"'

# VPN client -> company LAN.
nft 'insert rule inet filter forward iifname "tun0" oifname "eth2" ip saddr 10.9.0.0/24 ip daddr 172.30.0.0/16 counter accept comment "csa-lab9-openvpn-forward-out"'

# Company LAN -> established VPN flows.
nft 'insert rule inet filter forward iifname "eth2" oifname "tun0" ip saddr 172.30.0.0/16 ip daddr 10.9.0.0/24 ct state established,related counter accept comment "csa-lab9-openvpn-forward-return"'
EOF

chmod 0755 /usr/local/sbin/csa-openvpn-firewall-apply

cat >/etc/systemd/system/csa-openvpn-firewall.service <<'EOF'
[Unit]
Description=CSA Lab 9 OpenVPN nftables integration
After=network-online.target csa-firewall.service nftables.service
Wants=network-online.target
Before=openvpn-server@server.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/csa-openvpn-firewall-apply
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

# If the Lab 4/6 firewall service exists, make every future reload
# automatically restore the Lab-9 rules as well.
if systemctl cat csa-firewall.service >/dev/null 2>&1; then

    mkdir -p /etc/systemd/system/csa-firewall.service.d

    cat >/etc/systemd/system/csa-firewall.service.d/50-openvpn.conf <<'EOF'
[Service]
ExecStartPost=/usr/local/sbin/csa-openvpn-firewall-apply
EOF
fi

systemctl daemon-reload
systemctl enable csa-openvpn-firewall.service
systemctl restart csa-openvpn-firewall.service

echo
echo '=== 9. EXPORT CLIENT MATERIAL ==='

rm -rf /home/vagrant/lab9-client-export
mkdir -p /home/vagrant/lab9-client-export

install -m 0644 pki/ca.crt \
    /home/vagrant/lab9-client-export/ca.crt

install -m 0644 pki/issued/remote-employee.crt \
    /home/vagrant/lab9-client-export/remote-employee.crt

install -m 0600 pki/private/remote-employee.key \
    /home/vagrant/lab9-client-export/remote-employee.key

install -m 0600 /etc/openvpn/server/ta.key \
    /home/vagrant/lab9-client-export/ta.key

chown -R vagrant:vagrant /home/vagrant/lab9-client-export

echo
echo '=== 10. START OPENVPN SERVER ==='

systemctl daemon-reload
systemctl enable --now openvpn-server@server

sleep 3

systemctl --no-pager --full status \
    openvpn-server@server

echo
echo '=== 11. SERVER TUNNEL ==='

ip -br address show tun0
ip route

echo
echo '=== 12. UDP/1194 LISTENER ==='

ss -lunp | grep ':1194'

echo
echo '=== 13. LAB 9 FIREWALL RULES ==='

nft -a list chain inet filter input |
    grep 'csa-lab9'

nft -a list chain inet filter forward |
    grep 'csa-lab9'

echo
echo '=================================================='
echo 'COMPANYROUTER CONFIGURATION COMPLETE'
echo '=================================================='