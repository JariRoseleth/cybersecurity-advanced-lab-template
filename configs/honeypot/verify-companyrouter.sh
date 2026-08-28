#!/usr/bin/env bash
set -Eeuo pipefail

require_events=0
if [[ "${1:-}" == "--require-events" ]]; then
    require_events=1
fi

pass() {
    printf 'PASS: %s\n' "$*"
}

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

printf '%s\n' '=================================================='
printf '%s\n' 'CSA LAB 4 - COMPANYROUTER VERIFICATION'
printf '%s\n' '=================================================='
date -Is
hostname

[[ "$(sysctl -n net.ipv4.ip_forward)" == "1" ]] || fail 'IPv4 forwarding is not enabled'
pass 'IPv4 forwarding remains enabled'

systemctl is-active --quiet nftables || fail 'nftables is not active'
pass 'nftables is active'

systemctl is-active --quiet sshd || fail 'sshd is not active'
sshd -t

# Capture producer output first.  With pipefail enabled, piping a long producer
# into grep -q can falsely fail with SIGPIPE/141 after grep finds its match.
sshd_effective="$(sshd -T)"
printf '\n=== Effective SSH listener configuration ===\n'
awk '$1 == "port" || $1 == "listenaddress" { print }' <<< "$sshd_effective"

if ! awk '
    $1 == "port" {
        count++
        if ($2 != "2222") bad = 1
    }
    END { exit(count > 0 && bad == 0 ? 0 : 1) }
' <<< "$sshd_effective"; then
    fail 'real sshd is not configured exclusively with Port 2222'
fi

if ! awk '
    $1 == "listenaddress" {
        count++
        if ($2 !~ /:2222$/) bad = 1
    }
    END { exit(count > 0 && bad == 0 ? 0 : 1) }
' <<< "$sshd_effective"; then
    fail 'sshd has an effective ListenAddress outside TCP/2222'
fi

listen_tcp_processes="$(ss -H -lntp)"
printf '\n=== Active TCP listeners ===\n%s\n' "$listen_tcp_processes"
if ! awk '
    $4 ~ /:2222$/ && $0 ~ /sshd/ { found = 1 }
    END { exit(found ? 0 : 1) }
' <<< "$listen_tcp_processes"; then
    fail 'sshd is not listening on TCP/2222'
fi
if awk '
    $4 ~ /:22$/ && $0 ~ /sshd/ { found = 1 }
    END { exit(found ? 0 : 1) }
' <<< "$listen_tcp_processes"; then
    fail 'the real sshd still listens on TCP/22'
fi
pass 'real management SSH listens only on TCP/2222'

systemctl is-active --quiet docker || fail 'Docker is not active'
jq -e '."ip-forward-no-drop" == true' /etc/docker/daemon.json >/dev/null || fail 'Docker router-safe forwarding option is missing'
docker inspect cowrie >/dev/null 2>&1 || fail 'Cowrie container does not exist'
[[ "$(docker inspect --format '{{.State.Running}}' cowrie)" == 'true' ]] || fail 'Cowrie container is not running'

listen_tcp="$(ss -H -lnt)"
if ! awk '
    $4 == "192.168.62.253:2223" { found = 1 }
    END { exit(found ? 0 : 1) }
' <<< "$listen_tcp"; then
    fail 'Cowrie is not listening on 192.168.62.253:2223'
fi

grep -Eq '^backend[[:space:]]*=[[:space:]]*shell$' /opt/cowrie/etc/cowrie.cfg || fail 'Cowrie is not explicitly using the emulated shell backend'
container_user="$(docker inspect --format '{{.Config.User}}' cowrie)"
[[ -n "$container_user" && "$container_user" != '0' && "$container_user" != 'root' ]] || fail 'Cowrie is not configured as a non-root container user'
[[ "$(docker inspect --format '{{.HostConfig.ReadonlyRootfs}}' cowrie)" == 'true' ]] || fail 'Cowrie root filesystem is not read-only'
cap_drop="$(docker inspect --format '{{json .HostConfig.CapDrop}}' cowrie)"
[[ "$cap_drop" == *'"ALL"'* ]] || fail 'Cowrie did not drop all Linux capabilities'
security_options="$(docker inspect --format '{{json .HostConfig.SecurityOpt}}' cowrie)"
[[ "$security_options" == *'no-new-privileges'* ]] || fail 'Cowrie lacks no-new-privileges'
pass "Cowrie uses the shell emulator and hardened non-root container isolation ($container_user)"

prerouting_chain="$(nft list chain inet csa_firewall prerouting)"
input_chain="$(nft list chain inet csa_firewall input)"
forward_chain="$(nft list chain inet csa_firewall forward)"
[[ "$prerouting_chain" == *'dport 22'* ]] || fail 'SSH redirect is missing'
[[ "$prerouting_chain" == *'redirect to :2223'* ]] || fail 'redirect to Cowrie/2223 is missing'
[[ "$input_chain" == *'dport 2222 accept'* ]] || fail 'management firewall rule is missing'
[[ "$forward_chain" == *'172.30.0.10 tcp dport 80 accept'* ]] || fail 'published web rule is missing'
pass 'honeypot, management, and forwarding firewall rules are loaded'

json_log='/opt/cowrie/var/log/cowrie/cowrie.json'
if [[ -f "$json_log" ]]; then
    failed_count="$(grep -c 'cowrie.login.failed' "$json_log" || true)"
    success_count="$(grep -c 'cowrie.login.success' "$json_log" || true)"
    command_count="$(grep -c 'cowrie.command.input' "$json_log" || true)"
else
    failed_count=0
    success_count=0
    command_count=0
fi

printf 'Cowrie failed logins:     %s\n' "$failed_count"
printf 'Cowrie successful logins: %s\n' "$success_count"
printf 'Cowrie commands:          %s\n' "$command_count"

if (( require_events == 1 )); then
    (( failed_count >= 1 )) || fail 'no failed login event was recorded'
    (( success_count >= 1 )) || fail 'no successful login event was recorded'
    (( command_count >= 1 )) || fail 'no command input event was recorded'
    pass 'controlled attacker activity is present in the JSON audit log'
fi

printf '%s\n' '=================================================='
printf '%s\n' 'VERIFICATION COMPLETED'
printf '%s\n' '=================================================='
