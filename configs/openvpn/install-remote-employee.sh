#!/usr/bin/env bash
set -Eeuo pipefail

echo
echo '=================================================='
echo 'CSA LAB 9 - REMOTE EMPLOYEE'
echo '=================================================='

test "$(hostname)" = "remote-employee"

echo
echo '=== 1. INSTALL OPENVPN ==='

dnf -y install epel-release
dnf -y install openvpn

openvpn --version | head -n 3

echo
echo '=== 2. INSTALL CLIENT MATERIAL ==='

mkdir -p /etc/openvpn/client

install -m 0644 \
    /home/vagrant/lab9-client-import/client.conf \
    /etc/openvpn/client/client.conf

install -m 0644 \
    /home/vagrant/lab9-client-import/ca.crt \
    /etc/openvpn/client/ca.crt

install -m 0644 \
    /home/vagrant/lab9-client-import/remote-employee.crt \
    /etc/openvpn/client/remote-employee.crt

install -m 0600 \
    /home/vagrant/lab9-client-import/remote-employee.key \
    /etc/openvpn/client/remote-employee.key

install -m 0600 \
    /home/vagrant/lab9-client-import/ta.key \
    /etc/openvpn/client/ta.key

echo
echo '=== 3. CERTIFICATE VALIDATION ==='

openssl x509 \
    -in /etc/openvpn/client/remote-employee.crt \
    -noout \
    -subject \
    -issuer \
    -dates \
    -ext extendedKeyUsage

openssl verify \
    -CAfile /etc/openvpn/client/ca.crt \
    /etc/openvpn/client/remote-employee.crt

echo
echo '=== 4. START CLIENT ==='

systemctl daemon-reload
systemctl enable --now openvpn-client@client

sleep 5

systemctl --no-pager --full status \
    openvpn-client@client

echo
echo '=== 5. TUNNEL INTERFACE ==='

ip -br address show tun0

echo
echo '=== 6. ROUTING ==='

ip route

echo
echo '=== 7. ROUTE TO COMPANY LAN ==='

ip route get 172.30.0.4
ip route get 172.30.0.10
ip route get 172.30.0.15

echo
echo '=================================================='
echo 'REMOTE EMPLOYEE CONFIGURATION COMPLETE'
echo '=================================================='