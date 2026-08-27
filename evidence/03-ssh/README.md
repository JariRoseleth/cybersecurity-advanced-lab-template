# Lab 3 - Secure SSH access

## Implementation

An Ed25519 key pair was generated on the Windows administration host.

- The private key remains exclusively on the Windows host.
- The public key was added to `/home/vagrant/.ssh/authorized_keys`.
- The Windows SSH client stores verified server fingerprints in `known_hosts`.
- Password authentication was disabled for the validation commands on the client side.

## Bastion architecture

`companyrouter` is the bastion host for the internal company network.

Examples:

    ssh companyrouter
    ssh web
    ssh database
    ssh dns
    ssh employee

The internal aliases use:

    ProxyJump companyrouter

`homerouter` is the bastion host for `remote-employee`.

## Local port forwarding

The following command creates two encrypted tunnels:

    ssh -N \
        -L 127.0.0.1:8080:172.30.0.10:80 \
        -L 127.0.0.1:33060:172.30.0.15:3306 \
        companyrouter

The internal webserver is then available on:

    http://127.0.0.1:8080

The internal database is available on:

    127.0.0.1:33060

## Security reasoning

The firewall continues to block direct access from the untrusted network. Only a user possessing the private key and its passphrase can create the SSH tunnel through the bastion.

The private key must never be transferred to a server or committed to Git.

## Local versus remote forwarding

Local forwarding (`-L`) exposes a remote service on the SSH client's machine.

Remote forwarding (`-R`) exposes a service reachable by the SSH client on the SSH server's side.

Local forwarding is commonly used by administrators to reach protected internal services. Remote forwarding can also be used for legitimate support scenarios, but may create an unintended route around normal firewall policy.

## Evidence

- `ssh-key-and-bastion-tests.txt`
- `local-forwarding-tests.txt`
- `client-public-key.txt`

## Rollback

- Remove the CSA block from the Windows SSH config.
- Remove the matching `jari-csa-2026` line from `authorized_keys`.
- Stop active forwarding sessions with Ctrl+C.
