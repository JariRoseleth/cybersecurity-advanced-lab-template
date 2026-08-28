[CmdletBinding()]
param(
    [string]$RepoRoot = 'C:\dev\cybersecurity-advanced-lab-template',
    [switch]$RemoveLocalKeys
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
$Evidence = Join-Path $RepoRoot 'evidence\08-ipsec'
$CompanyFirewall = Join-Path $RepoRoot 'configs\firewall\companyrouter.nft'
$BackupFirewall = Join-Path $Evidence 'companyrouter-firewall-before-lab8.nft'

function Invoke-Ssh {
    param(
        [Parameter(Mandatory)][string]$Node,
        [Parameter(Mandatory)][string]$Command
    )

    & ssh -o BatchMode=yes -o ConnectTimeout=12 $Node $Command
    if ($LASTEXITCODE -ne 0) {
        throw "Rollback command failed on $Node."
    }
}

Set-Location -LiteralPath $RepoRoot

foreach ($node in @('companyrouter', 'homerouter')) {
    Invoke-Ssh `
        -Node $node `
        -Command @'
sudo systemctl disable --now csa-homerouter-firewall.service 2>/dev/null || true
sudo systemctl disable --now csa-ipsec.service 2>/dev/null || true
sudo systemctl disable --now csa-lab8-routing.service 2>/dev/null || true
sudo ip xfrm policy flush
sudo ip xfrm state flush
sudo rm -f \
    /etc/csa-ipsec.env \
    /etc/sysctl.d/90-csa-lab8-forwarding.conf \
    /etc/systemd/system/csa-ipsec.service \
    /etc/systemd/system/csa-lab8-routing.service \
    /usr/local/sbin/csa-ipsec-apply \
    /usr/local/sbin/csa-ipsec-clear \
    /usr/local/sbin/csa-lab8-routing \
    /usr/local/sbin/csa-lab8-test-traffic
sudo systemctl daemon-reload
'@
}

Invoke-Ssh `
    -Node companyrouter `
    -Command @'
sudo /usr/local/sbin/csa-companyrouter-firewall-runtime cleanup 2>/dev/null || true
sudo rm -f /usr/local/sbin/csa-companyrouter-firewall-runtime /usr/local/sbin/csa-lab8-router-capture
sudo ip route del 172.10.10.0/24 via 192.168.62.42 2>/dev/null || true
'@

Invoke-Ssh `
    -Node homerouter `
    -Command @'
sudo nft delete table inet csa_homerouter 2>/dev/null || true
sudo ip route del 172.30.0.0/16 via 192.168.62.253 2>/dev/null || true
if sudo test -e /var/lib/csa-lab8/firewalld-was-active; then
    sudo systemctl enable --now firewalld
fi
sudo rm -f \
    /etc/nftables/csa-homerouter-firewall.nft \
    /etc/systemd/system/csa-homerouter-firewall.service \
    /usr/local/sbin/csa-homerouter-firewall-apply \
    /usr/local/sbin/csa-lab8-test-traffic
sudo rm -f /var/lib/csa-lab8/firewalld-was-active
sudo systemctl daemon-reload
'@

if (Test-Path -LiteralPath $BackupFirewall) {
    Copy-Item `
        -LiteralPath $BackupFirewall `
        -Destination $CompanyFirewall `
        -Force

    & scp `
        -q `
        -o BatchMode=yes `
        $BackupFirewall `
        companyrouter:/tmp/companyrouter-before-lab8.nft

    if ($LASTEXITCODE -ne 0) {
        throw 'Could not copy the original companyrouter firewall back.'
    }

    Invoke-Ssh `
        -Node companyrouter `
        -Command @'
sudo nft --check --file /tmp/companyrouter-before-lab8.nft
sudo install -D -m 0644 /tmp/companyrouter-before-lab8.nft /etc/nftables/csa-firewall.nft
rm -f /tmp/companyrouter-before-lab8.nft
'@
}

if ($RemoveLocalKeys) {
    Remove-Item `
        -LiteralPath (Join-Path $RepoRoot 'configs\ipsec\ipsec.env') `
        -Force `
        -ErrorAction SilentlyContinue
}

Write-Host 'CSA Lab 8 runtime configuration was rolled back.' -ForegroundColor Green
Write-Host 'Evidence was retained.' -ForegroundColor Yellow
