#!/usr/bin/env bash
set -Eeuo pipefail

export DEBIAN_FRONTEND=noninteractive

LOG='/var/log/csa-lab7-siem-provision.log'
INSTALL_LOG='/root/wazuh-install-output.log'
EVIDENCE_DIR='/vagrant/evidence/07-siem'
EVIDENCE="$EVIDENCE_DIR/01-siem-server-health.txt"

mkdir -p "$EVIDENCE_DIR"

touch "$LOG"
chmod 0600 "$LOG"

exec > >(tee -a "$LOG") 2>&1

trap 'echo "ERROR near line ${BASH_LINENO[0]}" >&2' ERR

echo '=================================================='
echo 'CSA LAB 7 - WAZUH SIEM ON UBUNTU 22.04'
echo '=================================================='
date -Is

timedatectl set-timezone Europe/Brussels || true

echo
echo '=== PACKAGES ==='

apt-get update

apt-get install -y \
    curl \
    ca-certificates \
    gnupg \
    tar \
    gzip \
    jq \
    cloud-guest-utils \
    xfsprogs \
    e2fsprogs \
    lvm2

echo
echo '=== ROOT FILESYSTEM ==='

ROOT_SOURCE="$(findmnt -n -o SOURCE /)"
ROOT_REAL="$(readlink -f "$ROOT_SOURCE")"
ROOT_FSTYPE="$(findmnt -n -o FSTYPE /)"

echo "Root source: $ROOT_SOURCE"
echo "Filesystem : $ROOT_FSTYPE"

PARENT_DISK="$(
    lsblk -ndo PKNAME "$ROOT_REAL" |
    head -n 1
)"

PARTITION_NUMBER="$(
    basename "$ROOT_REAL" |
    grep -oE '[0-9]+$' |
    head -n 1
)"

if [[ -n "$PARENT_DISK" && -n "$PARTITION_NUMBER" ]]; then
    growpart "/dev/$PARENT_DISK" "$PARTITION_NUMBER" || true
    partprobe "/dev/$PARENT_DISK" || true
    udevadm settle || true
fi

case "$ROOT_FSTYPE" in
    xfs)
        xfs_growfs /
        ;;
    ext2|ext3|ext4)
        resize2fs "$ROOT_REAL" || true
        ;;
esac

lsblk
df -hT /

ROOT_KB="$(df -Pk / | awk 'NR == 2 {print $2}')"

if (( ROOT_KB < 30 * 1024 * 1024 )); then
    echo 'ERROR: root filesystem is smaller than 30 GiB.'
    exit 1
fi

echo
echo '=== SWAP ==='

if ! swapon --show --noheadings | grep -q .; then
    fallocate -l 2G /swapfile ||
        dd if=/dev/zero of=/swapfile bs=1M count=2048

    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile

    grep -q '^/swapfile ' /etc/fstab ||
        echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

free -h
swapon --show

echo
echo '=== INDEXER KERNEL SETTING ==='

cat >/etc/sysctl.d/99-csa-wazuh.conf <<'SYSCTL'
vm.max_map_count=262144
SYSCTL

sysctl --system >/dev/null
sysctl vm.max_map_count

echo
echo '=== OPTIONAL UFW RULES ==='

if command -v ufw >/dev/null 2>&1; then
    ufw allow 443/tcp || true
    ufw allow 1514/tcp || true
    ufw allow 1515/tcp || true
    ufw allow 55000/tcp || true
fi

echo
echo '=== WAZUH INSTALLATION ==='

cd /root

curl \
    -fsSLo wazuh-install.sh \
    https://packages.wazuh.com/4.14/wazuh-install.sh

chmod 700 wazuh-install.sh

set +e

/root/wazuh-install.sh -a 2>&1 |
    tee "$INSTALL_LOG" |
    awk '
        BEGIN { IGNORECASE=1 }
        /password/ {
            print "[REDACTED PASSWORD LINE]"
            next
        }
        { print }
    '

RESULT=${PIPESTATUS[0]}

set -e

if [[ "$RESULT" -ne 0 ]]; then
    echo
    echo '=== INSTALLER FAILURE SUMMARY ==='

    grep -Ei \
        'error|failed|unsupported|user .*does not exist|not registered' \
        "$INSTALL_LOG" |
        tail -n 100 ||
        true

    exit "$RESULT"
fi

echo
echo '=== SERVICES ==='

SERVICES=(
    wazuh-indexer
    wazuh-manager
    filebeat
    wazuh-dashboard
)

for service in "${SERVICES[@]}"; do
    systemctl enable "$service"

    if ! systemctl is-active --quiet "$service"; then
        systemctl restart "$service"
    fi

    printf '%s=' "$service"
    systemctl is-active "$service"
done

echo
echo '=== WAIT FOR DASHBOARD ==='

READY=0

for _ in $(seq 1 60); do
    if curl -kfsS https://127.0.0.1/ >/dev/null; then
        READY=1
        break
    fi

    sleep 5
done

if [[ "$READY" -ne 1 ]]; then
    echo 'Dashboard did not become ready.'
    journalctl -u wazuh-dashboard -n 100 --no-pager || true
    exit 1
fi

echo 'Dashboard is reachable.'

echo
echo '=== EVIDENCE ==='

{
    echo '=================================================='
    echo 'CSA LAB 7 - WAZUH SERVER HEALTH'
    echo '=================================================='

    date -Is

    echo
    echo '=== OS ==='
    cat /etc/os-release

    echo
    echo '=== NETWORK ==='
    ip -br address
    ip route

    echo
    echo '=== STORAGE ==='
    lsblk
    df -hT /

    echo
    echo '=== MEMORY ==='
    free -h
    swapon --show

    echo
    echo '=== WAZUH PACKAGES ==='
    dpkg -l |
        grep -E \
            'wazuh-manager|wazuh-indexer|wazuh-dashboard|filebeat'

    echo
    echo '=== SERVICES ==='

    for service in "${SERVICES[@]}"; do
        printf '%s=' "$service"
        systemctl is-active "$service"
    done

    echo
    echo '=== LISTENING PORTS ==='
    ss -lntp |
        grep -E \
            ':443|:1514|:1515|:55000|:9200' ||
        true

    echo
    echo '=== DASHBOARD ==='
    curl -kIs https://127.0.0.1/ |
        head -n 12

    echo
    echo '=== CREDENTIAL ARCHIVE ==='

    if [[ -f /root/wazuh-install-files.tar ]]; then
        echo 'PRESENT'
    else
        echo 'MISSING'
    fi
} > "$EVIDENCE"

cat "$EVIDENCE"

mkdir -p /var/lib/csa

date -Is > /var/lib/csa/lab7-siem-ready

echo
echo '=================================================='
echo 'LAB 7 WAZUH SERVER READY'
echo '=================================================='
