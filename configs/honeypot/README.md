# Lab 4 - Cowrie SSH honeypot

This directory contains the reproducible configuration for the Lab 4 SSH honeypot on `companyrouter`.

- Real management SSH listens on TCP/2222; the managed listener block is placed at the start of `/etc/ssh/sshd_config` so it wins before vendor/Vagrant includes.
- nftables redirects traffic addressed to `192.168.62.253:22` to Cowrie's private TCP/2223 listener.
- Forwarded SSH traffic to internal hosts remains untouched because the redirect is restricted to the router's own external IP address.
- Cowrie 3.0.13 runs as the official image's non-root `cowrie` user, with all Linux capabilities dropped, a read-only root filesystem, `no-new-privileges`, a PID limit and a memory limit.
- Docker uses `ip-forward-no-drop` so the host remains a router.
- JSON events, text logs, downloads and TTY sessions persist under `/opt/cowrie/var`.

Controlled lab credentials:

- `root` / `toor`
- `admin` / `password123`

These are decoy credentials for the isolated lab only. They are not real administrative credentials.

## Isolation and impact

- `backend = shell` keeps every attacker command inside Cowrie's Python-based UNIX emulation; Cowrie is not configured as a proxy to a real backend.
- The container runs as a non-root user, drops all Linux capabilities, has a read-only root filesystem, uses `no-new-privileges`, and is constrained by PID and memory limits.
- The attacker network reaches only redirected TCP/22. Real management TCP/2222 and Cowrie's private TCP/2223 listener remain blocked from `red`.
- Transferred artifacts and TTY/audit data are stored under `/opt/cowrie/var`; attacker-entered commands are logged rather than executed on `companyrouter`.
- The controlled test therefore cannot create real users, modify host files, or obtain a real administrative shell on the router.
