[CmdletBinding()]
param(
    [ValidateSet('Preflight', 'Baseline', 'Install', 'Verify', 'All')]
    [string]$Phase = 'All',

    [string]$RepoRoot = 'C:\dev\cybersecurity-advanced-lab-template',

    [switch]$SkipMitm,

    [switch]$Commit,

    [switch]$Push
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if ($Push -and -not $Commit) {
    throw '-Push requires -Commit.'
}

$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$Evidence = Join-Path $RepoRoot 'evidence\08-ipsec'
$ConfigRoot = Join-Path $RepoRoot 'configs\ipsec'
$CompanyFirewall = Join-Path $RepoRoot 'configs\firewall\companyrouter.nft'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

New-Item -ItemType Directory -Path $Evidence, $ConfigRoot -Force |
    Out-Null
Set-Location -LiteralPath $RepoRoot

function Write-Section {
    param([Parameter(Mandatory)][string]$Title)

    Write-Host ''
    Write-Host ('=' * 72) -ForegroundColor DarkCyan
    Write-Host $Title -ForegroundColor Cyan
    Write-Host ('=' * 72) -ForegroundColor DarkCyan
}

function Write-Utf8NoBom {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Content
    )

    [System.IO.File]::WriteAllText(
        $Path,
        ($Content -replace "`r`n", "`n").TrimEnd() + "`n",
        $script:Utf8NoBom
    )
}

function Invoke-Ssh {
    param(
        [Parameter(Mandatory)][string]$Node,
        [Parameter(Mandatory)][string]$Command,
        [switch]$AllowFailure
    )

    $previousErrorActionPreference = $ErrorActionPreference

    try {
        $ErrorActionPreference = 'Continue'

        $output = & ssh `
            -o BatchMode=yes `
            -o ConnectTimeout=12 `
            $Node `
            $Command 2>&1

        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }

    if (-not $AllowFailure -and $exitCode -ne 0) {
        throw "SSH command failed on ${Node}:`n$($output -join "`n")"
    }

    [pscustomobject]@{
        Node = $Node
        Command = $Command
        ExitCode = $exitCode
        Output = @($output)
    }
}

function Save-Result {
    param(
        [Parameter(Mandatory)]$Result,
        [Parameter(Mandatory)][string]$Path,
        [switch]$Append
    )

    $header = @(
        "Node: $($Result.Node)"
        "Command: $($Result.Command)"
        "ExitCode: $($Result.ExitCode)"
        ''
    )
    $content = ($header + $Result.Output) -join "`n"

    if ($Append) {
        Add-Content -LiteralPath $Path -Value $content -Encoding UTF8
    }
    else {
        Write-Utf8NoBom -Path $Path -Content $content
    }
}

function Copy-ToNode {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Node,
        [Parameter(Mandatory)][string]$Destination
    )

    & scp `
        -q `
        -o BatchMode=yes `
        -o ConnectTimeout=12 `
        $Source `
        "${Node}:$Destination"

    if ($LASTEXITCODE -ne 0) {
        throw "Could not copy $Source to ${Node}:$Destination."
    }
}

function Copy-FromNode {
    param(
        [Parameter(Mandatory)][string]$Node,
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination,
        [switch]$Optional
    )

    & scp `
        -q `
        -o BatchMode=yes `
        -o ConnectTimeout=12 `
        "${Node}:$Source" `
        $Destination

    if ($LASTEXITCODE -ne 0 -and -not $Optional) {
        throw "Could not copy ${Node}:$Source to $Destination."
    }
}

function Install-RemoteFile {
    param(
        [Parameter(Mandatory)][string]$Node,
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination,
        [ValidateSet('0600', '0644', '0700', '0755')]
        [string]$Mode = '0644'
    )

    $temporary = "/tmp/csa-lab8-$([IO.Path]::GetFileName($Destination))"
    Copy-ToNode -Source $Source -Node $Node -Destination $temporary
    Invoke-Ssh `
        -Node $Node `
        -Command "sudo install -D -m $Mode '$temporary' '$Destination' && rm -f '$temporary'" |
        Out-Null
}

function Wait-RemoteFile {
    param(
        [Parameter(Mandatory)][string]$Node,
        [Parameter(Mandatory)][string]$Path,
        [int]$Attempts = 60,
        [int]$DelayMilliseconds = 500
    )

    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        $result = Invoke-Ssh `
            -Node $Node `
            -Command "sudo test -e '$Path'" `
            -AllowFailure

        if ($result.ExitCode -eq 0) {
            return
        }

        Start-Sleep -Milliseconds $DelayMilliseconds
    }

    throw "Timed out waiting for $Path on $Node."
}

function New-HexKey {
    $bytes = New-Object byte[] 32
    $generator = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $generator.GetBytes($bytes)
    }
    finally {
        $generator.Dispose()
    }
    return -join ($bytes | ForEach-Object { $_.ToString('x2') })
}

function Ensure-SecretEnvironment {
    $secretPath = Join-Path $ConfigRoot 'ipsec.env'

    if (-not (Test-Path -LiteralPath $secretPath)) {
        $content = @"
CSA_HOME_WAN=192.168.62.42
CSA_COMPANY_WAN=192.168.62.253
CSA_HOME_NET=172.10.10.0/24
CSA_COMPANY_NET=172.30.0.0/16
CSA_H2C_SPI=0x00008001
CSA_C2H_SPI=0x00008002
CSA_H2C_REQID=8001
CSA_C2H_REQID=8002
CSA_H2C_AUTH_KEY=$(New-HexKey)
CSA_H2C_ENC_KEY=$(New-HexKey)
CSA_C2H_AUTH_KEY=$(New-HexKey)
CSA_C2H_ENC_KEY=$(New-HexKey)
"@
        Write-Utf8NoBom -Path $secretPath -Content $content
        Write-Host "Generated new local IPsec keys: $secretPath" -ForegroundColor Yellow
    }
    else {
        Write-Host "Reusing existing local IPsec keys: $secretPath" -ForegroundColor Yellow
    }

    $gitIgnore = Join-Path $RepoRoot '.gitignore'
    $ignoreRule = 'configs/ipsec/ipsec.env'
    $ignoreText = if (Test-Path -LiteralPath $gitIgnore) {
        Get-Content -LiteralPath $gitIgnore -Raw
    }
    else {
        ''
    }

    if ($ignoreText -notmatch '(?m)^configs/ipsec/ipsec[.]env\s*$') {
        Add-Content `
            -LiteralPath $gitIgnore `
            -Value "`n# CSA Lab 8 locally generated IPsec secrets`n$ignoreRule" `
            -Encoding UTF8
    }

    & git check-ignore --quiet -- 'configs/ipsec/ipsec.env'
    if ($LASTEXITCODE -ne 0) {
        throw 'configs/ipsec/ipsec.env is not ignored by Git.'
    }

    return $secretPath
}

function Ensure-RouterPackages {
    param([Parameter(Mandatory)][string]$Node)

    $command = @'
set -Eeuo pipefail
missing=0
for command_name in ip nft tcpdump systemctl; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
        missing=1
    fi
done
if [ "$missing" -eq 1 ]; then
    sudo dnf -y install iproute nftables tcpdump
fi
command -v ip
command -v nft
command -v tcpdump
command -v systemctl
'@

    Invoke-Ssh -Node $Node -Command $command | Out-Null
}

function Ensure-RemoteEmployeePackages {
    $command = @'
set -Eeuo pipefail

need_curl=0
need_ping=0
command -v curl >/dev/null 2>&1 || need_curl=1
command -v ping >/dev/null 2>&1 || need_ping=1

if [ "$need_curl" -eq 1 ] || [ "$need_ping" -eq 1 ]; then
    if command -v dnf >/dev/null 2>&1; then
        packages=''
        [ "$need_curl" -eq 0 ] || packages="$packages curl"
        [ "$need_ping" -eq 0 ] || packages="$packages iputils"
        sudo dnf -y install $packages
    elif command -v apk >/dev/null 2>&1; then
        packages=''
        [ "$need_curl" -eq 0 ] || packages="$packages curl"
        [ "$need_ping" -eq 0 ] || packages="$packages iputils"
        sudo apk add --no-cache $packages
    else
        echo 'No supported package manager found for curl/ping.' >&2
        exit 1
    fi
fi

command -v curl
command -v ping
'@
    Invoke-Ssh -Node remote-employee -Command $command | Out-Null
}

function Install-Routing {
    $routingScript = Join-Path $ConfigRoot 'csa-lab8-routing'
    $routingUnit = Join-Path $ConfigRoot 'csa-lab8-routing.service'

    foreach ($node in @('companyrouter', 'homerouter')) {
        Install-RemoteFile `
            -Node $node `
            -Source $routingScript `
            -Destination '/usr/local/sbin/csa-lab8-routing' `
            -Mode '0755'
        Install-RemoteFile `
            -Node $node `
            -Source $routingUnit `
            -Destination '/etc/systemd/system/csa-lab8-routing.service' `
            -Mode '0644'

        $null = Invoke-Ssh `
            -Node $node `
            -Command @'
sudo tee /etc/sysctl.d/90-csa-lab8-forwarding.conf >/dev/null <<'EOF'
net.ipv4.ip_forward = 1
net.ipv4.conf.all.rp_filter = 0
net.ipv4.conf.default.rp_filter = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
EOF
sudo sysctl --system >/dev/null
sudo systemctl daemon-reload
sudo systemctl enable csa-lab8-routing.service >/dev/null
sudo systemctl restart csa-lab8-routing.service
'@
    }
}

function Install-HelperScripts {
    Install-RemoteFile `
        -Node companyrouter `
        -Source (Join-Path $ScriptRoot 'csa-companyrouter-firewall-runtime') `
        -Destination '/usr/local/sbin/csa-companyrouter-firewall-runtime' `
        -Mode '0755'

    Install-RemoteFile `
        -Node companyrouter `
        -Source (Join-Path $ScriptRoot 'csa-lab8-router-capture') `
        -Destination '/usr/local/sbin/csa-lab8-router-capture' `
        -Mode '0755'

    foreach ($node in @('remote-employee', 'companyrouter', 'homerouter')) {
        Install-RemoteFile `
            -Node $node `
            -Source (Join-Path $ScriptRoot 'csa-lab8-test-traffic') `
            -Destination '/usr/local/sbin/csa-lab8-test-traffic' `
            -Mode '0755'
    }
}

function Prepare-RedMitm {
    if ($SkipMitm) {
        return $false
    }

    $probe = Invoke-Ssh `
        -Node red `
        -Command 'command -v ettercap >/dev/null 2>&1 && command -v tcpdump >/dev/null 2>&1' `
        -AllowFailure

    if ($probe.ExitCode -ne 0) {
        Write-Host 'Installing Ettercap/tcpdump on red for MITM evidence...' `
            -ForegroundColor Yellow

        $installCommand = @'
sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq &&
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ettercap-text-only tcpdump
'@
        $install = Invoke-Ssh `
            -Node red `
            -Command $installCommand `
            -AllowFailure

        if ($install.ExitCode -ne 0) {
            Save-Result `
                -Result $install `
                -Path (Join-Path $Evidence '00-red-mitm-unavailable.txt')
            Write-Warning 'Ettercap could not be installed. Router-side captures will still be produced.'
            return $false
        }
    }

    Install-RemoteFile `
        -Node red `
        -Source (Join-Path $ScriptRoot 'csa-lab8-red-capture') `
        -Destination '/usr/local/sbin/csa-lab8-red-capture' `
        -Mode '0755'

    return $true
}

function Start-CompanyCapture {
    param([Parameter(Mandatory)][string]$Label)

    $base = "/tmp/csa-lab8-${Label}-companyrouter"
    Invoke-Ssh `
        -Node companyrouter `
        -Command "sudo rm -f ${base}.*; sudo nohup /usr/local/sbin/csa-lab8-router-capture '$Label' 30 >${base}-nohup.log 2>&1 &" |
        Out-Null
    Wait-RemoteFile -Node companyrouter -Path "${base}.ready"
}

function Stop-CompanyCapture {
    param([Parameter(Mandatory)][string]$Label)

    $base = "/tmp/csa-lab8-${Label}-companyrouter"
    Invoke-Ssh `
        -Node companyrouter `
        -Command "if sudo test -s '${base}.pid'; then sudo kill -INT `$(sudo cat '${base}.pid') 2>/dev/null || true; fi" `
        -AllowFailure |
        Out-Null
    Wait-RemoteFile -Node companyrouter -Path "${base}.done"
}

function Start-RedCapture {
    param([Parameter(Mandatory)][string]$Label)

    $base = "/tmp/csa-lab8-${Label}-red"
    Invoke-Ssh `
        -Node red `
        -Command "sudo rm -f ${base}*; sudo nohup /usr/local/sbin/csa-lab8-red-capture '$Label' 30 >${base}-nohup.log 2>&1 &" |
        Out-Null
    Wait-RemoteFile -Node red -Path "${base}.ready"
}

function Stop-RedCapture {
    param([Parameter(Mandatory)][string]$Label)

    $base = "/tmp/csa-lab8-${Label}-red"
    $command = @"
for f in '${base}-ettercap.pid' '${base}-tcpdump.pid'; do
    if sudo test -s "`$f"; then
        sudo kill -INT `$(sudo cat "`$f") 2>/dev/null || true
    fi
done
"@
    Invoke-Ssh -Node red -Command $command -AllowFailure | Out-Null
    Wait-RemoteFile -Node red -Path "${base}.done"
}

function Invoke-Traffic {
    param([Parameter(Mandatory)][string]$OutputPath)

    $results = @(
        Invoke-Ssh `
            -Node remote-employee `
            -Command 'sudo /usr/local/sbin/csa-lab8-test-traffic remote' `
            -AllowFailure
        Invoke-Ssh `
            -Node companyrouter `
            -Command 'sudo /usr/local/sbin/csa-lab8-test-traffic company' `
            -AllowFailure
        Invoke-Ssh `
            -Node homerouter `
            -Command 'sudo /usr/local/sbin/csa-lab8-test-traffic home' `
            -AllowFailure
    )

    Remove-Item -LiteralPath $OutputPath -Force -ErrorAction SilentlyContinue
    foreach ($result in $results) {
        Save-Result -Result $result -Path $OutputPath -Append
    }

    return $results
}

function Collect-CompanyCapture {
    param([Parameter(Mandatory)][string]$Label)

    $base = "/tmp/csa-lab8-${Label}-companyrouter"
    $pcap = Join-Path $Evidence "${Label}-companyrouter.pcap"
    Copy-FromNode `
        -Node companyrouter `
        -Source "${base}.pcap" `
        -Destination $pcap

    $summary = Invoke-Ssh `
        -Node companyrouter `
        -Command "sudo tcpdump -nn -tttt -r '${base}.pcap' 2>/dev/null"
    Save-Result `
        -Result $summary `
        -Path (Join-Path $Evidence "${Label}-companyrouter-summary.txt")

    return $pcap
}

function Collect-RedCapture {
    param([Parameter(Mandatory)][string]$Label)

    $base = "/tmp/csa-lab8-${Label}-red"
    foreach ($remoteName in @(
        "${base}.pcap",
        "${base}-tcpdump.log",
        "${base}-ettercap.log"
    )) {
        $leaf = [IO.Path]::GetFileName($remoteName)
        Copy-FromNode `
            -Node red `
            -Source $remoteName `
            -Destination (Join-Path $Evidence $leaf) `
            -Optional
    }

    $summary = Invoke-Ssh `
        -Node red `
        -Command "sudo tcpdump -nn -tttt -r '${base}.pcap' 2>/dev/null" `
        -AllowFailure
    Save-Result `
        -Result $summary `
        -Path (Join-Path $Evidence "${Label}-red-summary.txt")
}

function Get-PcapCount {
    param(
        [Parameter(Mandatory)][string]$Node,
        [Parameter(Mandatory)][string]$RemotePcap,
        [Parameter(Mandatory)][string]$Filter
    )

    $result = Invoke-Ssh `
        -Node $Node `
        -Command "sudo tcpdump -nn -r '$RemotePcap' '$Filter' 2>/dev/null | wc -l"

    $value = ($result.Output | Select-Object -Last 1).ToString().Trim()
    return [int]$value
}

function Invoke-Preflight {
    Write-Section 'LAB 8 - PREFLIGHT'

    foreach ($command in @('git', 'vagrant', 'ssh', 'scp')) {
        if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
            throw "Required command is unavailable: $command"
        }
    }

    & git status --short 2>&1 |
        Set-Content -LiteralPath (Join-Path $Evidence '00-git-status-before.txt') -Encoding UTF8
    & git log -1 --oneline --decorate 2>&1 |
        Set-Content -LiteralPath (Join-Path $Evidence '00-git-head-before.txt') -Encoding UTF8
    & vagrant status 2>&1 |
        Set-Content -LiteralPath (Join-Path $Evidence '00-vagrant-status.txt') -Encoding UTF8

    $preflightPath = Join-Path $Evidence '00-preflight.txt'
    Remove-Item -LiteralPath $preflightPath -Force -ErrorAction SilentlyContinue

    foreach ($node in @(
        'companyrouter',
        'homerouter',
        'remote-employee'
    )) {
        $result = Invoke-Ssh `
            -Node $node `
            -Command @'
echo '=== HOSTNAME ==='
hostname
echo '=== ADDRESSES ==='
ip -br address
echo '=== ROUTES ==='
ip route
echo '=== FORWARDING ==='
sysctl net.ipv4.ip_forward 2>/dev/null || true
echo '=== REQUIRED COMMANDS ==='
for command_name in ip nft tcpdump systemctl curl ping; do
    printf '%-12s ' "$command_name"
    command -v "$command_name" 2>/dev/null || echo MISSING
done
echo '=== SUDO ==='
sudo -n true && echo OK
'@
        Save-Result -Result $result -Path $preflightPath -Append
    }

    foreach ($node in @('companyrouter', 'homerouter')) {
        Ensure-RouterPackages -Node $node
    }
    Ensure-RemoteEmployeePackages

    Install-Routing
    Install-HelperScripts

    Write-Host 'Preflight succeeded.' -ForegroundColor Green
}

function Invoke-Baseline {
    Write-Section 'LAB 8 - PLAINTEXT BASELINE AND MITM EVIDENCE'

    Install-Routing
    Install-HelperScripts

    foreach ($node in @('companyrouter', 'homerouter')) {
        Invoke-Ssh `
            -Node $node `
            -Command 'sudo systemctl stop csa-ipsec.service 2>/dev/null || true; sudo ip xfrm policy flush; sudo ip xfrm state flush' `
            -AllowFailure |
            Out-Null
    }

    # A previous Lab 8 run must not make the deliberately insecure baseline fail.
    $baselineHomeCommand = @'
sudo install -d -m 0700 /var/lib/csa-lab8
if sudo systemctl is-active --quiet firewalld; then
    sudo touch /var/lib/csa-lab8/firewalld-was-active
fi
sudo systemctl disable --now firewalld 2>/dev/null || true
sudo systemctl stop csa-homerouter-firewall.service 2>/dev/null || true
sudo nft delete table inet csa_homerouter 2>/dev/null || true
'@
    $null = Invoke-Ssh `
        -Node homerouter `
        -Command $baselineHomeCommand `
        -AllowFailure

    Invoke-Ssh `
        -Node companyrouter `
        -Command 'sudo /usr/local/sbin/csa-companyrouter-firewall-runtime baseline' |
        Out-Null

    $mitmAvailable = Prepare-RedMitm

    Start-CompanyCapture -Label '02-plaintext'
    if ($mitmAvailable) {
        Start-RedCapture -Label '02-plaintext'
    }

    $traffic = Invoke-Traffic `
        -OutputPath (Join-Path $Evidence '02-plaintext-connectivity.txt')

    Stop-CompanyCapture -Label '02-plaintext'
    if ($mitmAvailable) {
        Stop-RedCapture -Label '02-plaintext'
    }

    Collect-CompanyCapture -Label '02-plaintext' | Out-Null
    if ($mitmAvailable) {
        Collect-RedCapture -Label '02-plaintext'
    }

    $plaintextCount = Get-PcapCount `
        -Node companyrouter `
        -RemotePcap '/tmp/csa-lab8-02-plaintext-companyrouter.pcap' `
        -Filter 'net 172.10.10.0/24 and net 172.30.0.0/16'

    $baselineSummary = @"
Plaintext packets crossing companyrouter fake-internet interface: $plaintextCount
MITM capture on red attempted: $mitmAvailable
"@
    Write-Utf8NoBom `
        -Path (Join-Path $Evidence '02-plaintext-validation.txt') `
        -Content $baselineSummary

    if ($plaintextCount -lt 1) {
        throw 'The baseline capture did not contain plaintext inter-site packets.'
    }

    if (@($traffic | Where-Object ExitCode -ne 0).Count -gt 0) {
        throw 'At least one baseline connectivity test failed.'
    }

    Write-Host "Plaintext baseline proved with $plaintextCount captured packets." `
        -ForegroundColor Green
}

function Invoke-Install {
    Write-Section 'LAB 8 - INSTALL IPSEC, ROUTING AND FAIL-CLOSED FIREWALLS'

    $secretPath = Ensure-SecretEnvironment
    Install-Routing
    Install-HelperScripts

    foreach ($node in @('companyrouter', 'homerouter')) {
        Install-RemoteFile `
            -Node $node `
            -Source (Join-Path $ConfigRoot 'csa-ipsec-apply') `
            -Destination '/usr/local/sbin/csa-ipsec-apply' `
            -Mode '0755'
        Install-RemoteFile `
            -Node $node `
            -Source (Join-Path $ConfigRoot 'csa-ipsec-clear') `
            -Destination '/usr/local/sbin/csa-ipsec-clear' `
            -Mode '0755'
        Install-RemoteFile `
            -Node $node `
            -Source (Join-Path $ConfigRoot 'csa-ipsec.service') `
            -Destination '/etc/systemd/system/csa-ipsec.service' `
            -Mode '0644'
        Install-RemoteFile `
            -Node $node `
            -Source $secretPath `
            -Destination '/etc/csa-ipsec.env' `
            -Mode '0600'
    }

    $homeFirewallPreparation = @'
sudo install -d -m 0700 /var/lib/csa-lab8
if sudo systemctl is-active --quiet firewalld; then
    sudo touch /var/lib/csa-lab8/firewalld-was-active
fi
sudo systemctl disable --now firewalld 2>/dev/null || true
'@
    $null = Invoke-Ssh `
        -Node homerouter `
        -Command $homeFirewallPreparation

    Install-RemoteFile `
        -Node homerouter `
        -Source (Join-Path $ConfigRoot 'csa-homerouter-firewall.nft') `
        -Destination '/etc/nftables/csa-homerouter-firewall.nft' `
        -Mode '0644'
    Install-RemoteFile `
        -Node homerouter `
        -Source (Join-Path $ConfigRoot 'csa-homerouter-firewall-apply') `
        -Destination '/usr/local/sbin/csa-homerouter-firewall-apply' `
        -Mode '0755'
    Install-RemoteFile `
        -Node homerouter `
        -Source (Join-Path $ConfigRoot 'csa-homerouter-firewall.service') `
        -Destination '/etc/systemd/system/csa-homerouter-firewall.service' `
        -Mode '0644'

    $firewallBackup = Join-Path $Evidence 'companyrouter-firewall-before-lab8.nft'
    & (Join-Path $ScriptRoot 'Patch-CompanyRouterFirewall.ps1') `
        -Path $CompanyFirewall `
        -BackupPath $firewallBackup

    Copy-ToNode `
        -Source $CompanyFirewall `
        -Node companyrouter `
        -Destination '/tmp/csa-companyrouter-lab8.nft'

    $companyFirewallInstall = @'
sudo nft --check --file /tmp/csa-companyrouter-lab8.nft
sudo install -D -m 0644 /tmp/csa-companyrouter-lab8.nft /etc/nftables/csa-firewall.nft
rm -f /tmp/csa-companyrouter-lab8.nft
'@
    $null = Invoke-Ssh `
        -Node companyrouter `
        -Command $companyFirewallInstall

    foreach ($node in @('companyrouter', 'homerouter')) {
        Invoke-Ssh `
            -Node $node `
            -Command 'sudo systemctl daemon-reload; sudo systemctl enable csa-lab8-routing.service csa-ipsec.service >/dev/null; sudo systemctl restart csa-lab8-routing.service; sudo systemctl restart csa-ipsec.service' |
            Out-Null
    }

    Invoke-Ssh `
        -Node companyrouter `
        -Command 'sudo /usr/local/sbin/csa-companyrouter-firewall-runtime secure' |
        Out-Null

    Invoke-Ssh `
        -Node homerouter `
        -Command 'sudo systemctl daemon-reload; sudo systemctl enable csa-homerouter-firewall.service >/dev/null; sudo systemctl restart csa-homerouter-firewall.service' |
        Out-Null

    foreach ($node in @('companyrouter', 'homerouter')) {
        $state = Invoke-Ssh `
            -Node $node `
            -Command "sudo ip xfrm state list | grep -c '^src '; sudo ip xfrm policy list | grep -c '^src '"
        $counts = @(
            $state.Output |
                ForEach-Object { $_.ToString().Trim() } |
                Where-Object { $_ -match '^\d+$' }
        )

        if ($counts.Count -lt 2 -or
            [int]$counts[0] -ne 2 -or
            [int]$counts[1] -ne 3) {
            throw "Unexpected XFRM object count on $node."
        }
    }

    Write-Host 'IPsec and both fail-closed firewall policies are active.' `
        -ForegroundColor Green
}

function Invoke-Verify {
    Write-Section 'LAB 8 - ENCRYPTION, BIDIRECTIONAL TRAFFIC AND FAIL-CLOSED TESTS'

    $mitmAvailable = Prepare-RedMitm

    Start-CompanyCapture -Label '05-esp'
    if ($mitmAvailable) {
        Start-RedCapture -Label '05-esp'
    }

    $traffic = Invoke-Traffic `
        -OutputPath (Join-Path $Evidence '04-connectivity-after.txt')

    Stop-CompanyCapture -Label '05-esp'
    if ($mitmAvailable) {
        Stop-RedCapture -Label '05-esp'
    }

    Collect-CompanyCapture -Label '05-esp' | Out-Null
    if ($mitmAvailable) {
        Collect-RedCapture -Label '05-esp'
    }

    $espCount = Get-PcapCount `
        -Node companyrouter `
        -RemotePcap '/tmp/csa-lab8-05-esp-companyrouter.pcap' `
        -Filter 'esp'

    $plaintextCount = Get-PcapCount `
        -Node companyrouter `
        -RemotePcap '/tmp/csa-lab8-05-esp-companyrouter.pcap' `
        -Filter 'net 172.10.10.0/24 and net 172.30.0.0/16'

    if (@($traffic | Where-Object ExitCode -ne 0).Count -gt 0) {
        throw 'At least one encrypted connectivity test failed.'
    }
    if ($espCount -lt 1) {
        throw 'The encrypted capture contains no ESP packets.'
    }
    # A tcpdump on companyrouter itself can see the inner packet again after
    # inbound XFRM decapsulation. Therefore it is not a valid wire-level
    # plaintext test. Use red as the independent observer on fake internet.
    $companyLocalPlaintextCount = $plaintextCount

    if (-not $mitmAvailable) {
        throw 'Wire-level IPsec validation requires the red MITM capture.'
    }

    $wireEspCount = Get-PcapCount `
        -Node red `
        -RemotePcap '/tmp/csa-lab8-05-esp-red.pcap' `
        -Filter 'esp and host 192.168.62.42 and host 192.168.62.253'

    $wirePlaintextCount = Get-PcapCount `
        -Node red `
        -RemotePcap '/tmp/csa-lab8-05-esp-red.pcap' `
        -Filter 'net 172.10.10.0/24 and net 172.30.0.0/16'

    if ($wireEspCount -lt 1) {
        throw 'The external red capture contains no ESP packets.'
    }

    if ($wirePlaintextCount -ne 0) {
        throw "The external red capture contains $wirePlaintextCount plaintext inter-site packets."
    }

    # From this point on the validation summary represents the actual wire,
    # not companyrouter's post-decryption AF_PACKET view.
    $espCount = $wireEspCount
    $plaintextCount = $wirePlaintextCount

    $captureValidation = @"
ESP packets observed on fake-internet wire by red: $espCount
Plaintext inter-site packets observed on fake-internet wire by red: $plaintextCount
Companyrouter local plaintext copies after XFRM decapsulation: $companyLocalPlaintextCount
MITM capture on red attempted: $mitmAvailable
Result: PASS
"@
    Write-Utf8NoBom `
        -Path (Join-Path $Evidence '05-esp-validation.txt') `
        -Content $captureValidation

    foreach ($node in @('companyrouter', 'homerouter')) {
        $xfrm = Invoke-Ssh `
            -Node $node `
            -Command @'
echo '=== XFRM STATES WITHOUT KEYS ==='
sudo ip -s xfrm state list nokeys
echo '=== XFRM POLICIES ==='
sudo ip xfrm policy list
echo '=== ROUTES ==='
ip route
'@
        Save-Result `
            -Result $xfrm `
            -Path (Join-Path $Evidence "03-xfrm-${node}.txt")
    }

    $negativePath = Join-Path $Evidence '04-negative-fail-closed.txt'
    $stopResult = Invoke-Ssh `
        -Node homerouter `
        -Command 'sudo systemctl stop csa-ipsec.service'
    Save-Result -Result $stopResult -Path $negativePath

    $blocked = Invoke-Ssh `
        -Node remote-employee `
        -Command 'ping -c 2 -W 2 172.30.0.10 >/dev/null 2>&1' `
        -AllowFailure
    Save-Result -Result $blocked -Path $negativePath -Append

    if ($blocked.ExitCode -eq 0) {
        Invoke-Ssh `
            -Node homerouter `
            -Command 'sudo systemctl start csa-ipsec.service' `
            -AllowFailure |
            Out-Null
        throw 'Fail-closed test failed: plaintext connectivity survived after XFRM was stopped.'
    }

    Invoke-Ssh `
        -Node homerouter `
        -Command 'sudo systemctl start csa-ipsec.service; sudo systemctl restart csa-homerouter-firewall.service' |
        Out-Null
    Invoke-Ssh `
        -Node companyrouter `
        -Command 'sudo systemctl restart csa-ipsec.service; sudo /usr/local/sbin/csa-companyrouter-firewall-runtime secure' |
        Out-Null

    $recovered = Invoke-Ssh `
        -Node remote-employee `
        -Command 'ping -c 3 -W 2 172.30.0.10 >/dev/null && (curl -kfsSL --max-time 10 http://172.30.0.10/ >/dev/null || curl -kfsSL --max-time 10 https://172.30.0.10/ >/dev/null)' `
        -AllowFailure
    Save-Result -Result $recovered -Path $negativePath -Append

    if ($recovered.ExitCode -ne 0) {
        throw 'Connectivity did not recover after IPsec was restarted.'
    }

    $companyFirewallResult = Invoke-Ssh `
        -Node companyrouter `
        -Command "sudo nft -a list ruleset | grep -B1 -A1 'CSA-LAB8' || true"
    Save-Result `
        -Result $companyFirewallResult `
        -Path (Join-Path $Evidence '06-companyrouter-firewall.txt')

    $homeFirewallResult = Invoke-Ssh `
        -Node homerouter `
        -Command 'sudo nft -a list table inet csa_homerouter'
    Save-Result `
        -Result $homeFirewallResult `
        -Path (Join-Path $Evidence '06-homerouter-firewall.txt')

    $servicesPath = Join-Path $Evidence '07-services.txt'
    Remove-Item -LiteralPath $servicesPath -Force -ErrorAction SilentlyContinue

    foreach ($node in @('companyrouter', 'homerouter')) {
        $services = Invoke-Ssh `
            -Node $node `
            -Command @'
systemctl is-enabled csa-lab8-routing.service
systemctl is-active csa-lab8-routing.service
systemctl is-enabled csa-ipsec.service
systemctl is-active csa-ipsec.service
systemctl status csa-ipsec.service --no-pager
'@
        Save-Result -Result $services -Path $servicesPath -Append
    }

    $homeService = Invoke-Ssh `
        -Node homerouter `
        -Command 'systemctl is-enabled csa-homerouter-firewall.service; systemctl is-active csa-homerouter-firewall.service'
    Save-Result -Result $homeService -Path $servicesPath -Append

    Write-Host "Verification passed: $espCount ESP packets and zero plaintext packets." `
        -ForegroundColor Green
}

function Update-EvidenceReadme {
    $mitmText = if ($SkipMitm) {
        'The red/Ettercap phase was explicitly skipped.'
    }
    else {
        'The script attempted the course-required ARP-spoofing capture on red. Check the red pcap and Ettercap log; when package installation was unavailable, the router-side capture remains the primary proof.'
    }

    $template = @'
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

__MITM_TEXT__

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
'@

    $readme = $template.Replace('__MITM_TEXT__', $mitmText)
    Write-Utf8NoBom `
        -Path (Join-Path $Evidence 'README.md') `
        -Content $readme
}

function Commit-Lab8 {
    Write-Section 'LAB 8 - ISOLATED COMMIT'

    & git diff --cached --quiet
    if ($LASTEXITCODE -ne 0) {
        throw 'There are already staged changes. Nothing was committed.'
    }

    $paths = @(
        '.gitignore',
        'README-LAB8.md',
        'configs/ipsec',
        'configs/firewall/companyrouter.nft',
        'scripts/lab8',
        'evidence/08-ipsec'
    )

    & git add -- @paths
    if ($LASTEXITCODE -ne 0) {
        throw 'git add failed.'
    }

    $staged = @(& git diff --cached --name-only)
    if ($staged -contains 'configs/ipsec/ipsec.env') {
        & git restore --staged -- 'configs/ipsec/ipsec.env'
        throw 'The real IPsec key file was staged and has been removed from the index.'
    }

    $stagedPath = Join-Path $Evidence '08-staged-files.txt'
    $staged |
        Set-Content -LiteralPath $stagedPath -Encoding UTF8
    & git add -- 'evidence/08-ipsec/08-staged-files.txt'
    if ($LASTEXITCODE -ne 0) {
        throw 'Could not stage the final staged-file manifest.'
    }

    & git commit -m 'feat: add fail-closed site-to-site IPsec lab'
    if ($LASTEXITCODE -ne 0) {
        throw 'git commit failed.'
    }

    if ($Push) {
        & git push origin main
        if ($LASTEXITCODE -ne 0) {
            throw 'git push failed.'
        }
    }
}

switch ($Phase) {
    'Preflight' {
        Invoke-Preflight
    }
    'Baseline' {
        Invoke-Preflight
        Invoke-Baseline
    }
    'Install' {
        Invoke-Preflight
        Invoke-Install
    }
    'Verify' {
        Invoke-Preflight
        Invoke-Verify
    }
    'All' {
        Invoke-Preflight
        Invoke-Baseline
        Invoke-Install
        Invoke-Verify
    }
}

Update-EvidenceReadme

if ($Commit) {
    Commit-Lab8
}

Write-Section 'LAB 8 COMPLETED'
Write-Host "Evidence: $Evidence" -ForegroundColor Green
Write-Host 'Real IPsec keys were not printed and are excluded from Git.' -ForegroundColor Green
