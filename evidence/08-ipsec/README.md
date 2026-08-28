# Lab 8 - Site-to-site IPsec

## Scope

A bidirectional manual IPsec tunnel protects all traffic between:

- home LAN: `172.10.10.0/24`
- company LAN: `172.30.0.0/16`
- homerouter fake-internet address: `192.168.62.42`
- companyrouter fake-internet address: `192.168.62.253`

The implementation uses two ESP Security Associations and three policies on
each router. The `in`, `out` and `fwd` directions are installed together so
successive scripts cannot erase one another.

## Evidence sequence

1. `02-plaintext-*` proves that inter-site traffic was visible before IPsec.
2. `03-xfrm-*` records states, policies and counters without exposing keys.
3. `04-connectivity-after.txt` proves traffic in both directions.
4. `04-negative-fail-closed.txt` proves that stopping XFRM blocks selected
   traffic and that restarting it restores connectivity.
5. `05-esp-*` proves ESP is present and matching plaintext is absent.
6. `06-*firewall.txt` and `07-services.txt` prove persistent configuration.

The script attempted the course-required ARP-spoofing capture on red. Check the red pcap and Ettercap log; when package installation was unavailable, the router-side capture remains the primary proof.

## Secrets

The real keys live only in `configs/ipsec/ipsec.env` and `/etc/csa-ipsec.env`.
The local file is ignored by Git. Only the example file is committed.

## Re-run

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\scripts\lab8\Invoke-CSA-Lab8.ps1 -Phase Verify
```

## Rollback

```powershell
.\scripts\lab8\Rollback-CSA-Lab8.ps1
```
