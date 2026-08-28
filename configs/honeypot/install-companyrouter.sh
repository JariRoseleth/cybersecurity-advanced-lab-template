#!/usr/bin/env bash
set -Eeuo pipefail
umask 027

SRC="${1:-/tmp/csa-lab4}"
INSTALL_DIR='/opt/cowrie'
SSHD_CONFIG='/etc/ssh/sshd_config'
SSH_DROPIN='/etc/ssh/sshd_config.d/10-csa-management-port.conf'
DOCKER_CONFIG='/etc/docker/daemon.json'
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP="/root/csa-lab4-backup-${STAMP}"

log() {
    printf '\n=== %s ===\n' "$*"
}

for required in \
    "$SRC/companyrouter.nft" \
    "$SRC/compose.yaml" \
    "$SRC/cowrie.cfg" \
    "$SRC/userdb.txt" \
    "$SRC/docker-daemon.json" \
    "$SRC/verify-companyrouter.sh"; do
    [[ -f "$required" ]] || {
        echo "Missing staged file: $required" >&2
        exit 1
    }
done

NFT_CONFIG="$(
    systemctl cat nftables 2>/dev/null |
        awk '
            /^[[:space:]]*ExecStart=/ {
                for (i = 1; i <= NF; i++) {
                    if (!found && $i == "-f" && i < NF) {
                        print $(i + 1)
                        found = 1
                    }
                }
            }
        '
)"

if [[ -z "$NFT_CONFIG" ]]; then
    if [[ -e /etc/sysconfig/nftables.conf ]]; then
        NFT_CONFIG='/etc/sysconfig/nftables.conf'
    else
        NFT_CONFIG='/etc/nftables.conf'
    fi
fi

mkdir -p "$BACKUP"
printf '%s\n' "$NFT_CONFIG" > "$BACKUP/nft-config-path"
nft list ruleset > "$BACKUP/active-ruleset.nft"

# The effective SSH port must be recoverable even when a distribution or
# Vagrant drop-in wins over a later local drop-in. Back up the authoritative
# main configuration before putting the managed directives at its beginning.
cp -a "$SSHD_CONFIG" "$BACKUP/sshd_config"

if [[ -e "$NFT_CONFIG" ]]; then
    cp -a "$NFT_CONFIG" "$BACKUP/nftables.conf"
    touch "$BACKUP/nft-config.existed"
fi

if [[ -e "$SSH_DROPIN" ]]; then
    cp -a "$SSH_DROPIN" "$BACKUP/ssh-dropin.conf"
    touch "$BACKUP/ssh-dropin.existed"
fi

if [[ -e "$DOCKER_CONFIG" ]]; then
    cp -a "$DOCKER_CONFIG" "$BACKUP/docker-daemon.json"
    touch "$BACKUP/docker-config.existed"
fi

if [[ -d "$INSTALL_DIR" ]]; then
    cp -a "$INSTALL_DIR" "$BACKUP/cowrie"
    touch "$BACKUP/cowrie.existed"
fi

if command -v docker >/dev/null 2>&1 || rpm -q docker-ce >/dev/null 2>&1; then
    touch "$BACKUP/docker.existed"
    systemctl is-enabled --quiet docker 2>/dev/null && touch "$BACKUP/docker.enabled" || true
    systemctl is-active --quiet docker 2>/dev/null && touch "$BACKUP/docker.active" || true
fi

cat > "$BACKUP/rollback.sh" <<'ROLLBACK'
#!/usr/bin/env bash
set -u

BACKUP="$(cd "$(dirname "$0")" && pwd)"
INSTALL_DIR='/opt/cowrie'
SSHD_CONFIG='/etc/ssh/sshd_config'
SSH_DROPIN='/etc/ssh/sshd_config.d/10-csa-management-port.conf'
DOCKER_CONFIG='/etc/docker/daemon.json'
NFT_CONFIG="$(cat "$BACKUP/nft-config-path")"

printf '%s\n' 'Rolling back CSA Lab 4...'

if command -v docker >/dev/null 2>&1 && [[ -f "$INSTALL_DIR/compose.yaml" ]]; then
    docker compose -f "$INSTALL_DIR/compose.yaml" down --remove-orphans || true
fi

if [[ -e "$BACKUP/cowrie.existed" ]]; then
    rm -rf "$INSTALL_DIR"
    cp -a "$BACKUP/cowrie" "$INSTALL_DIR"
else
    rm -rf "$INSTALL_DIR"
fi

if [[ -f "$BACKUP/sshd_config" ]]; then
    cp -a "$BACKUP/sshd_config" "$SSHD_CONFIG"
    restorecon -F "$SSHD_CONFIG" >/dev/null 2>&1 || true
fi

if [[ -e "$BACKUP/ssh-dropin.existed" ]]; then
    cp -a "$BACKUP/ssh-dropin.conf" "$SSH_DROPIN"
else
    rm -f "$SSH_DROPIN"
fi

if [[ -e "$BACKUP/docker-config.existed" ]]; then
    mkdir -p "$(dirname "$DOCKER_CONFIG")"
    cp -a "$BACKUP/docker-daemon.json" "$DOCKER_CONFIG"
else
    rm -f "$DOCKER_CONFIG"
fi

if [[ -e "$BACKUP/docker.existed" ]]; then
    if [[ -e "$BACKUP/docker.active" ]]; then
        systemctl restart docker || true
    else
        systemctl stop docker containerd || true
    fi
    if [[ -e "$BACKUP/docker.enabled" ]]; then
        systemctl enable docker >/dev/null 2>&1 || true
    else
        systemctl disable docker >/dev/null 2>&1 || true
    fi
else
    # Docker was introduced by this lab. Leave installed packages available,
    # but do not leave a new daemon active after a failed/explicit rollback.
    systemctl disable --now docker containerd >/dev/null 2>&1 || true
fi

if [[ -e "$BACKUP/nft-config.existed" ]]; then
    mkdir -p "$(dirname "$NFT_CONFIG")"
    cp -a "$BACKUP/nftables.conf" "$NFT_CONFIG"
    nft -f "$NFT_CONFIG"
else
    rm -f "$NFT_CONFIG"
    nft flush ruleset
    nft -f "$BACKUP/active-ruleset.nft"
fi

if [[ -e "$BACKUP/selinux-port-added" ]]; then
    semanage port -d -t ssh_port_t -p tcp 2222 || true
elif [[ -e "$BACKUP/selinux-port-modified" ]]; then
    original_type="$(cat "$BACKUP/selinux-port-original-type")"
    semanage port -m -t "$original_type" -p tcp 2222 || true
fi

sshd -t && systemctl reload sshd

if [[ -e "$BACKUP/cowrie.existed" ]] && [[ -f "$INSTALL_DIR/compose.yaml" ]]; then
    docker compose -f "$INSTALL_DIR/compose.yaml" up -d || true
fi

printf '%s\n' 'Rollback completed.'
ROLLBACK
chmod 700 "$BACKUP/rollback.sh"
ln -sfn "$BACKUP" /root/csa-lab4-latest-backup

rollback_on_error() {
    rc=$?
    trap - ERR
    echo "Installation failed with exit code $rc; executing rollback." >&2
    "$BACKUP/rollback.sh" || true
    exit "$rc"
}
trap rollback_on_error ERR

log 'Install Docker prerequisites and SELinux management tools'
dnf -y install dnf-plugins-core policycoreutils-python-utils jq

if [[ ! -f /etc/yum.repos.d/docker-ce.repo ]]; then
    dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
fi

dnf -y install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

log 'Configure Docker without breaking router forwarding'
install -d -m 0755 /etc/docker
install -m 0644 "$SRC/docker-daemon.json" "$DOCKER_CONFIG"
dockerd --validate --config-file "$DOCKER_CONFIG"
systemctl enable --now docker
docker version
docker compose version
[[ "$(sysctl -n net.ipv4.ip_forward)" == '1' ]]

log 'Pull and prepare Cowrie'
docker pull cowrie/cowrie:3.0.13
COWRIE_IDS="$(
    docker run --rm --network none \
        --entrypoint /cowrie/cowrie-env/bin/python3 \
        cowrie/cowrie:3.0.13 \
        -c 'import pwd; p=pwd.getpwnam("cowrie"); print(f"{p.pw_uid}:{p.pw_gid}")'
)"
COWRIE_UID="${COWRIE_IDS%%:*}"
COWRIE_GID="${COWRIE_IDS##*:}"
[[ "$COWRIE_UID" =~ ^[0-9]+$ && "$COWRIE_GID" =~ ^[0-9]+$ ]]
[[ "$COWRIE_UID" != '0' ]]
printf 'Cowrie image runtime UID:GID = %s:%s\n' "$COWRIE_UID" "$COWRIE_GID"

install -d -m 0755 "$INSTALL_DIR"
install -d -o "$COWRIE_UID" -g "$COWRIE_GID" -m 0750 \
    "$INSTALL_DIR/etc" \
    "$INSTALL_DIR/var" \
    "$INSTALL_DIR/var/log/cowrie" \
    "$INSTALL_DIR/var/lib/cowrie" \
    "$INSTALL_DIR/var/lib/cowrie/downloads" \
    "$INSTALL_DIR/var/lib/cowrie/tty" \
    "$INSTALL_DIR/var/run"

install -o "$COWRIE_UID" -g "$COWRIE_GID" -m 0640 "$SRC/cowrie.cfg" "$INSTALL_DIR/etc/cowrie.cfg"
install -o "$COWRIE_UID" -g "$COWRIE_GID" -m 0640 "$SRC/userdb.txt" "$INSTALL_DIR/etc/userdb.txt"
install -m 0644 "$SRC/compose.yaml" "$INSTALL_DIR/compose.yaml"
install -m 0755 "$SRC/verify-companyrouter.sh" /usr/local/sbin/csa-lab4-verify

# Cowrie 3.x loads its defaults from the installed package.  The small
# operator-owned etc/cowrie.cfg below only overrides this lab's settings.

cd "$INSTALL_DIR"
docker compose config >/dev/null
docker compose up -d

cowrie_ready=0
for _ in $(seq 1 30); do
    current_listeners="$(ss -H -lnt)"
    if [[ "$(docker inspect --format '{{.State.Running}}' cowrie 2>/dev/null || true)" == 'true' ]] && \
       awk '''
           $4 == "192.168.62.253:2223" { found = 1 }
           END { exit(found ? 0 : 1) }
       ''' <<< "$current_listeners"; then
        cowrie_ready=1
        break
    fi
    sleep 1
done

[[ "$cowrie_ready" == '1' ]]
docker logs --tail 80 cowrie

log 'Allow real SSH on SELinux port 2222'
semanage_ports="$(semanage port -l)"
port_2222_type="$(
    awk '''
        $2 == "tcp" {
            for (i = 3; i <= NF; i++) {
                token = $i
                gsub(/,/, "", token)
                if (!found && token == "2222") {
                    found = 1
                    type = $1
                }
            }
        }
        END {
            if (found) print type
        }
    ''' <<< "$semanage_ports"
)"

if [[ "$port_2222_type" != 'ssh_port_t' ]]; then
    if [[ -n "$port_2222_type" ]]; then
        printf '%s\n' "$port_2222_type" > "$BACKUP/selinux-port-original-type"
        semanage port -m -t ssh_port_t -p tcp 2222
        touch "$BACKUP/selinux-port-modified"
    else
        semanage port -a -t ssh_port_t -p tcp 2222
        touch "$BACKUP/selinux-port-added"
    fi
fi

log 'Validate and stage SSH and nftables atomically'

# RHEL-family sshd configuration is first-value-wins for many keywords. A
# Vagrant/vendor file can therefore keep Port 22 effective even when a later
# drop-in says Port 2222. Put the managed listener directives before every
# Include and every other setting in the authoritative main configuration.
SSHD_BASE="$(mktemp)"
SSHD_NEW="$(mktemp /etc/ssh/sshd_config.csa-lab4.XXXXXX)"

awk '
    $0 == "# BEGIN CSA LAB 4 MANAGEMENT SSH" { managed = 1; next }
    $0 == "# END CSA LAB 4 MANAGEMENT SSH"   { managed = 0; next }
    managed != 1 { print }
' "$SSHD_CONFIG" > "$SSHD_BASE"

{
    printf '%s\n' \
        '# BEGIN CSA LAB 4 MANAGEMENT SSH' \
        '# Keep real administration away from the attacker-facing honeypot.' \
        'Port 2222' \
        'ListenAddress 0.0.0.0:2222' \
        'ListenAddress [::]:2222' \
        '# END CSA LAB 4 MANAGEMENT SSH'
    cat "$SSHD_BASE"
} > "$SSHD_NEW"

chown --reference="$SSHD_CONFIG" "$SSHD_NEW"
chmod --reference="$SSHD_CONFIG" "$SSHD_NEW"
mv -f "$SSHD_NEW" "$SSHD_CONFIG"
restorecon -F "$SSHD_CONFIG" >/dev/null 2>&1 || true
rm -f "$SSHD_BASE"

# Remove the V1/V2 local drop-in. Its original state is already in the backup
# and will be restored by rollback when it existed before this run.
rm -f "$SSH_DROPIN"

printf '%s\n' '=== Active Port/ListenAddress/Include directives ==='
grep -RniEi \
    '^[[:space:]]*(port|listenaddress|include)[[:space:]]+' \
    /etc/ssh/sshd_config \
    /etc/ssh/sshd_config.d \
    2>/dev/null || true

sshd -t
sshd_effective="$(sshd -T)"
printf '%s\n' '=== Effective SSH listener configuration before reload ==='
awk '$1 == "port" || $1 == "listenaddress" { print }' <<< "$sshd_effective"
awk '''
    $1 == "port" {
        count++
        if ($2 != "2222") bad = 1
    }
    END { exit(count > 0 && bad == 0 ? 0 : 1) }
''' <<< "$sshd_effective"
awk '''
    $1 == "listenaddress" {
        count++
        if ($2 !~ /:2222$/) bad = 1
    }
    END { exit(count > 0 && bad == 0 ? 0 : 1) }
''' <<< "$sshd_effective"

nft -c -f "$SRC/companyrouter.nft"

install -d -m 0755 "$(dirname "$NFT_CONFIG")"
install -m 0600 "$SRC/companyrouter.nft" "$NFT_CONFIG"
nft -f "$NFT_CONFIG"
systemctl enable nftables >/dev/null

# Reload preserves the SSH session carrying the installer while reopening the
# listening sockets from the now-validated main configuration.
systemctl reload sshd

ssh_listener_ready=0
for _ in $(seq 1 20); do
    current_listeners="$(ss -H -lntp)"
    if awk '''
           $4 ~ /:2222$/ && $0 ~ /sshd/ { found = 1 }
           END { exit(found ? 0 : 1) }
       ''' <<< "$current_listeners" && \
       ! awk '''
           $4 ~ /:22$/ && $0 ~ /sshd/ { found = 1 }
           END { exit(found ? 0 : 1) }
       ''' <<< "$current_listeners"; then
        ssh_listener_ready=1
        break
    fi
    sleep 1
done
[[ "$ssh_listener_ready" == '1' ]]

log 'Verify the switched services'
/usr/local/sbin/csa-lab4-verify

IMAGE_DIGEST="$(docker image inspect --format '{{index .RepoDigests 0}}' cowrie/cowrie:3.0.13 2>/dev/null || true)"
cat > "$INSTALL_DIR/install-summary.txt" <<SUMMARY
Installed: $(date -Is)
Persistent nftables file: $NFT_CONFIG
Real management SSH: TCP/2222
Attacker-facing honeypot: TCP/22 redirected to Cowrie TCP/2223
Cowrie image: ${IMAGE_DIGEST:-cowrie/cowrie:3.0.13}
Cowrie runtime UID:GID: ${COWRIE_UID}:${COWRIE_GID}
Rollback: /root/csa-lab4-latest-backup/rollback.sh
SUMMARY

trap - ERR
rm -rf "$SRC"

log 'CSA Lab 4 installation completed'
cat "$INSTALL_DIR/install-summary.txt"
