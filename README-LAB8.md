# CSA Lab 8 — complete IPsec implementation

This toolkit implements the current Lab 8 assignment as a reproducible,
bidirectional site-to-site IPsec tunnel.

## What it configures

- static routes between `172.10.10.0/24` and `172.30.0.0/16`;
- IPv4 forwarding on both gateways;
- two ESP Security Associations with separate AES-256/HMAC-SHA256 keys;
- all required `in`, `out` and `fwd` XFRM policies;
- persistent systemd services;
- fail-closed nftables rules on both gateways;
- a plaintext-before / ESP-after packet-capture comparison;
- an Ettercap ARP-spoofing capture from `red`, when available;
- bidirectional connectivity and tunnel-failure tests;
- isolated evidence and optional Git commit/push.

## Install the toolkit in the repository

Extract the ZIP directly into:

```text
C:\dev\cybersecurity-advanced-lab-template
```

PowerShell:

```powershell
$Repo = 'C:\dev\cybersecurity-advanced-lab-template'
Expand-Archive `
    -LiteralPath "$HOME\Downloads\CSA-Lab8-IPsec-Toolkit.zip" `
    -DestinationPath $Repo `
    -Force

Set-Location $Repo
Set-ExecutionPolicy -Scope Process Bypass
```

## Execute Lab 8

The safest first run does not commit anything:

```powershell
.\scripts\lab8\Invoke-CSA-Lab8.ps1 -Phase All
```

The phases can also be run separately:

```powershell
.\scripts\lab8\Invoke-CSA-Lab8.ps1 -Phase Preflight
.\scripts\lab8\Invoke-CSA-Lab8.ps1 -Phase Baseline
.\scripts\lab8\Invoke-CSA-Lab8.ps1 -Phase Install
.\scripts\lab8\Invoke-CSA-Lab8.ps1 -Phase Verify
```

Skip the optional red/Ettercap stage only when necessary:

```powershell
.\scripts\lab8\Invoke-CSA-Lab8.ps1 -Phase All -SkipMitm
```

After reviewing `evidence\08-ipsec`, make an isolated commit:

```powershell
.\scripts\lab8\Invoke-CSA-Lab8.ps1 `
    -Phase Verify `
    -Commit `
    -Push
```

The script refuses to commit when files are already staged and stages only the
Lab 8 paths. It never stages `configs\ipsec\ipsec.env`.

## Expected proof

A successful run produces evidence that:

- plaintext ICMP/HTTP was visible before IPsec;
- both routers have exactly two XFRM states and three policies;
- remote employee can reach the company network through the tunnel;
- company-originated traffic can return through the reverse SA;
- the fake-internet capture contains ESP;
- the encrypted capture contains no matching `172.10.10.0/24` ↔
  `172.30.0.0/16` plaintext;
- stopping XFRM blocks selected traffic instead of falling back to plaintext;
- restarting XFRM restores connectivity.

## Rollback

```powershell
.\scripts\lab8\Rollback-CSA-Lab8.ps1
```

Also remove the locally generated key file:

```powershell
.\scripts\lab8\Rollback-CSA-Lab8.ps1 -RemoveLocalKeys
```

## Security boundary

This is a manual-keying educational lab. The real random keys are generated
locally, installed as root-readable files and excluded from Git. A production
deployment should use an IKE daemon for authenticated negotiation, rekeying and
lifecycle management.
