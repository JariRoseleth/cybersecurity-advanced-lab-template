# Lab 2 - Network firewall

## Architecture

- WAN/untrusted interface: eth1, fake internet 192.168.62.0/24
- LAN/trusted interface: eth2, company network 172.30.0.0/16
- Firewall platform: nftables on companyrouter
- Default input policy: drop
- Default forward policy: drop
- Default output policy: accept

## Permitted traffic

- Existing and related connections
- Company LAN to the external network
- HTTP from the external network to web at 172.30.0.10
- SSH from the Windows management host to companyrouter
- SSH management from isprouter
- SSH from isprouter to internal machines for Ansible

## Blocked attack paths

- Direct external SSH access
- External DNS access and DNS zone transfers
- External MySQL access
- External access to the command-injection service on port 8000
- General external interaction with internal systems

## Validation

See:

- 02-firewall-after.txt
- internal-internet-after-firewall.txt
- active-ruleset.txt

## Rollback

Temporary rollback:

    sudo nft flush ruleset

Persistent rollback:

    sudo cp /etc/sysconfig/nftables.conf.before-csa /etc/sysconfig/nftables.conf
    sudo systemctl restart nftables

A VirtualBox snapshot was also created immediately before applying the firewall.

## Architectural limitation

The public webserver is still connected to the same layer-2 internal network as the other company hosts. A stronger architecture would place web in a separate DMZ with a third companyrouter interface. The current implementation still enforces the required WAN-to-LAN access policy but does not protect the LAN if the webserver itself becomes compromised.
