# Lab 1 and Lab 2 insecure baseline

## Goal

The red machine represents an attacker connected to the insecure fake-internet network.

## Red machine

- Address: 192.168.62.10/24
- Default gateway: 192.168.62.254
- DNS server: 192.168.62.254
- Network interfaces: one host-only interface
- Internet connectivity: working
- Internal network connectivity: working before firewall implementation

## Demonstrated weaknesses

- Internal hosts are reachable from the insecure network.
- Internal services can be enumerated with Nmap.
- The internal database is remotely reachable.
- The database accepts the credentials toor / summer.
- Default vagrant / vagrant SSH credentials can be tested.
- The public website and insecure command application are externally reachable.
- DNS zone-transfer behaviour was tested.

## Evidence

See `01-insecure-baseline.txt` for the commands and complete output.

## Planned remediation

- Separate the public webserver into a DMZ.
- Keep DNS, database and employee systems in the internal LAN.
- Configure companyrouter as a network firewall.
- Permit only required traffic between the external network, DMZ and LAN.
- Preserve internet access for internal systems.
