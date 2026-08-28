#!/usr/bin/env bash
set -Eeuo pipefail

TARGET='192.168.62.253'

printf '%s\n' '=================================================='
printf '%s\n' 'CSA LAB 4 - CONTROLLED RED TEST'
printf '%s\n' '=================================================='
date -Is
hostname
ip -4 route get "$TARGET"

if ! command -v nmap >/dev/null 2>&1 || ! command -v sshpass >/dev/null 2>&1; then
    sudo apt-get update -qq
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nmap sshpass
fi

printf '\n=== Port exposure ===\n'
nmap -Pn -n --reason -p 22,2222,2223 "$TARGET"

port_is_open() {
    local port="$1"
    timeout 4 bash -c "exec 3<>/dev/tcp/$TARGET/$port" >/dev/null 2>&1
}

port_is_open 22 || { echo 'FAIL: Cowrie is not reachable on TCP/22' >&2; exit 1; }
if port_is_open 2222; then
    echo 'FAIL: management TCP/2222 is exposed to red' >&2
    exit 1
fi
if port_is_open 2223; then
    echo 'FAIL: Cowrie private TCP/2223 is directly exposed to red' >&2
    exit 1
fi
printf '%s\n' 'PASS: red reaches only attacker-facing TCP/22'

printf '\n=== Deliberately failed authentication ===\n'
set +e
timeout 15 sshpass -p 'incorrect-lab-password' \
    ssh \
        -o ConnectTimeout=5 \
        -o ConnectionAttempts=1 \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o PreferredAuthentications=password \
        -o PubkeyAuthentication=no \
        -o KbdInteractiveAuthentication=no \
        -o NumberOfPasswordPrompts=1 \
        -o LogLevel=ERROR \
        admin@"$TARGET" 'echo THIS-MUST-NOT-RUN'
failed_rc=$?
set -e
printf 'Failed-login SSH exit code: %s (non-zero expected)\n' "$failed_rc"
[[ "$failed_rc" -ne 0 ]]

printf '\n=== Controlled successful Cowrie session ===\n'
set +e
printf '%s\n' \
    'whoami' \
    'id' \
    'hostname' \
    'uname -a' \
    'pwd' \
    'ls -la' \
    'cat /etc/passwd' \
    'echo CSA-LAB4-COWRIE-SESSION' \
    'exit' |
    timeout 25 sshpass -p 'toor' \
        ssh -tt \
            -o ConnectTimeout=5 \
            -o ConnectionAttempts=1 \
            -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile=/dev/null \
            -o PreferredAuthentications=password \
            -o PubkeyAuthentication=no \
            -o KbdInteractiveAuthentication=no \
            -o NumberOfPasswordPrompts=1 \
            -o LogLevel=ERROR \
            root@"$TARGET"
success_rc=$?
set -e
printf 'Cowrie-session SSH exit code: %s\n' "$success_rc"

printf '%s\n' '=================================================='
printf '%s\n' 'CONTROLLED RED TEST COMPLETED'
printf '%s\n' '=================================================='
