[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Path,

    [Parameter(Mandatory)]
    [string]$BackupPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not (Test-Path -LiteralPath $Path)) {
    throw "Firewall configuration not found: $Path"
}

$text = Get-Content -LiteralPath $Path -Raw
New-Item -ItemType Directory -Path (Split-Path -Parent $BackupPath) -Force |
    Out-Null

# Preserve the original configuration from the first Lab 8 run.
if (-not (Test-Path -LiteralPath $BackupPath)) {
    Copy-Item -LiteralPath $Path -Destination $BackupPath -Force
}

$markerPatterns = @(
    '(?ms)\s*# BEGIN CSA LAB 8 IPSEC INPUT.*?# END CSA LAB 8 IPSEC INPUT\s*',
    '(?ms)\s*# BEGIN CSA LAB 8 IPSEC FORWARD.*?# END CSA LAB 8 IPSEC FORWARD\s*',
    '(?ms)\s*# BEGIN CSA LAB 8 IPSEC OUTPUT.*?# END CSA LAB 8 IPSEC OUTPUT\s*'
)

foreach ($pattern in $markerPatterns) {
    $text = [regex]::Replace($text, $pattern, "`n")
}

$inputBlock = @'

        # BEGIN CSA LAB 8 IPSEC INPUT
        # Only homerouter may send ESP to companyrouter.
        ip saddr 192.168.62.42 ip daddr 192.168.62.253 ip protocol esp accept
        ip protocol esp drop

        # Accept home-to-company traffic only after successful IPsec processing.
        ip saddr 172.10.10.0/24 ip daddr 172.30.0.0/16 ipsec in reqid 8001 accept
        ip saddr 172.10.10.0/24 ip daddr 172.30.0.0/16 drop
        # END CSA LAB 8 IPSEC INPUT
'@

$forwardBlock = @'

        # BEGIN CSA LAB 8 IPSEC FORWARD
        # Home-to-company traffic must have arrived through reqid 8001.
        ip saddr 172.10.10.0/24 ip daddr 172.30.0.0/16 ipsec in reqid 8001 accept
        ip saddr 172.10.10.0/24 ip daddr 172.30.0.0/16 drop

        # Company-to-home traffic must leave through reqid 8002.
        ip saddr 172.30.0.0/16 ip daddr 172.10.10.0/24 ipsec out reqid 8002 accept
        ip saddr 172.30.0.0/16 ip daddr 172.10.10.0/24 drop
        # END CSA LAB 8 IPSEC FORWARD
'@

$outputBlock = @'

        # BEGIN CSA LAB 8 IPSEC OUTPUT
        # Router-originated company-to-home traffic must also be encrypted.
        ip saddr 172.30.0.0/16 ip daddr 172.10.10.0/24 ipsec out reqid 8002 accept
        ip saddr 172.30.0.0/16 ip daddr 172.10.10.0/24 drop
        # END CSA LAB 8 IPSEC OUTPUT
'@

function Insert-Block {
    param(
        [Parameter(Mandatory)]
        [string]$InputText,

        [Parameter(Mandatory)]
        [string]$Pattern,

        [Parameter(Mandatory)]
        [string]$Block,

        [Parameter(Mandatory)]
        [string]$Description
    )

    $regex = [regex]::new(
        $Pattern,
        [System.Text.RegularExpressions.RegexOptions]::Singleline
    )
    $match = $regex.Match($InputText)

    if (-not $match.Success) {
        throw "Could not locate insertion point for $Description."
    }

    return $InputText.Substring(0, $match.Index + $match.Length) +
        $Block +
        $InputText.Substring($match.Index + $match.Length)
}

# Insert before established/related so an old plaintext flow cannot bypass
# the fail-closed policy.
$text = Insert-Block `
    -InputText $text `
    -Pattern '(chain\s+input\s*\{.*?ct state invalid drop)' `
    -Block $inputBlock `
    -Description 'input chain'

$text = Insert-Block `
    -InputText $text `
    -Pattern '(chain\s+forward\s*\{.*?ct state invalid drop)' `
    -Block $forwardBlock `
    -Description 'forward chain'

$text = Insert-Block `
    -InputText $text `
    -Pattern '(chain\s+output\s*\{.*?policy accept;)' `
    -Block $outputBlock `
    -Description 'output chain'

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText(
    $Path,
    ($text -replace "`r`n", "`n").TrimEnd() + "`n",
    $utf8NoBom
)

Write-Host "Patched: $Path" -ForegroundColor Green
Write-Host "Original backup: $BackupPath" -ForegroundColor Yellow
