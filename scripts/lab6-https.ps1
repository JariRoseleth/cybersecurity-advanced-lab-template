[CmdletBinding()]
param(
    [string]$Repo = "C:\dev\cybersecurity-advanced-lab-template",
    [switch]$SkipPacketCaptures
)

$ScriptVersion = "2.3-vm-clock-skew-fix"

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$Succeeded = $false
$TranscriptStarted = $false

function Write-Heading {
    param([Parameter(Mandatory)][string]$Text)

    Write-Host ""
    Write-Host ("=" * 72) -ForegroundColor DarkCyan
    Write-Host $Text -ForegroundColor Cyan
    Write-Host ("=" * 72) -ForegroundColor DarkCyan
}

function Set-Utf8NoBomFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Content
    )

    $Parent = Split-Path -Parent $Path
    if ($Parent) {
        New-Item -ItemType Directory -Path $Parent -Force | Out-Null
    }

    $Normalized = $Content -replace "`r`n", "`n"
    [System.IO.File]::WriteAllText($Path, $Normalized, $script:Utf8NoBom)
}

function Add-Utf8NoBomText {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Content
    )

    [System.IO.File]::AppendAllText($Path, ($Content -replace "`r`n", "`n"), $script:Utf8NoBom)
}

function Invoke-Checked {
    param(
        [Parameter(Mandatory)][string]$Description,
        [Parameter(Mandatory)][scriptblock]$Action
    )

    Write-Host "[RUN] $Description" -ForegroundColor Yellow
    $global:LASTEXITCODE = 0

    # Windows PowerShell 5.1 can convert successful native stderr messages into
    # ErrorRecord objects. Do not treat those messages as failures; the native
    # process exit code remains the authoritative result.
    $ExitCode = 1
    $PreviousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        & $Action
        $ExitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $PreviousErrorActionPreference
    }

    if ($ExitCode -ne 0) {
        throw "$Description is mislukt met exitcode $ExitCode."
    }
}

function Copy-ToNode {
    param(
        [Parameter(Mandatory)][string]$Node,
        [Parameter(Mandatory)][string]$LocalPath,
        [Parameter(Mandatory)][string]$RemotePath
    )

    Invoke-Checked "Kopieer $(Split-Path -Leaf $LocalPath) naar $Node" {
        & scp $LocalPath ("{0}:{1}" -f $Node, $RemotePath)
    }
}

function Copy-FromNode {
    param(
        [Parameter(Mandatory)][string]$Node,
        [Parameter(Mandatory)][string]$RemotePath,
        [Parameter(Mandatory)][string]$LocalPath
    )

    $Parent = Split-Path -Parent $LocalPath
    if ($Parent) {
        New-Item -ItemType Directory -Path $Parent -Force | Out-Null
    }

    Invoke-Checked "Kopieer $(Split-Path -Leaf $RemotePath) van $Node" {
        & scp ("{0}:{1}" -f $Node, $RemotePath) $LocalPath
    }
}

function Invoke-NodeScript {
    param(
        [Parameter(Mandatory)][string]$Node,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Content,
        [string]$CaptureOutputPath
    )

    $SafeName = ($Name -replace '[^A-Za-z0-9_.-]', '-')
    $LocalScript = Join-Path $script:WorkDir ("{0}-{1}.sh" -f $Node, $SafeName)
    $RemoteScript = "/tmp/csa-lab6-$SafeName.sh"

    Set-Utf8NoBomFile -Path $LocalScript -Content (($Content.TrimEnd()) + "`n")
    Copy-ToNode -Node $Node -LocalPath $LocalScript -RemotePath $RemoteScript

    Write-Host "[RUN] $Name op $Node" -ForegroundColor Yellow
    $global:LASTEXITCODE = 0

    # OpenSSL and httpd legitimately write some success/status messages to
    # stderr. Windows PowerShell 5.1 must not abort while collecting those
    # messages; only the actual SSH exit code determines success or failure.
    $RawOutput = @()
    $Output = @()
    $ExitCode = 1
    $PreviousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $RawOutput = @(& ssh $Node "chmod 700 '$RemoteScript' && '$RemoteScript'" 2>&1)
        $ExitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $PreviousErrorActionPreference
    }

    $Output = @($RawOutput | ForEach-Object { $_.ToString() })
    $Output | ForEach-Object { Write-Output $_ }

    if ($CaptureOutputPath) {
        Add-Utf8NoBomText -Path $CaptureOutputPath -Content (("`n### {0} ({1})`n" -f $Name, $Node) + (($Output | Out-String).TrimEnd()) + "`n")
    }

    & ssh $Node "rm -f '$RemoteScript'" 2>$null | Out-Null

    if ($ExitCode -ne 0) {
        throw "$Name op $Node is mislukt met exitcode $ExitCode."
    }
}

function Apply-ApacheConfiguration {
    param(
        [Parameter(Mandatory)][string]$LocalConfig,
        [Parameter(Mandatory)][string]$Label
    )

    Copy-ToNode -Node "web" -LocalPath $LocalConfig -RemotePath "/tmp/csa-lab6-ssl.conf"

    $ApplyScript = @'
#!/bin/sh
set -eu

sudo install -m 0644 /tmp/csa-lab6-ssl.conf /etc/httpd/conf.d/ssl.conf
sudo sed -i 's#ProxyPassReverse "/aaa" "http://localhost:8000/"#ProxyPassReverse "/cmd" "http://localhost:8000/"#' /etc/httpd/conf/httpd.conf

if command -v restorecon >/dev/null 2>&1; then
    sudo restorecon -Rv /etc/httpd/conf.d /etc/pki/tls/certs /etc/pki/tls/private >/dev/null 2>&1 || true
fi

if systemctl is-active --quiet firewalld 2>/dev/null; then
    sudo firewall-cmd --permanent --add-service=https >/dev/null
    sudo firewall-cmd --reload >/dev/null
fi

sudo httpd -t
sudo systemctl restart httpd
sudo systemctl is-active --quiet httpd
sudo ss -lntp | grep -E '(:80|:443)[[:space:]]'
sudo httpd -t -D DUMP_VHOSTS 2>&1 || true
'@

    Invoke-NodeScript -Node "web" -Name ("apply-apache-{0}" -f $Label) -Content $ApplyScript
}

if (-not (Test-Path -LiteralPath $Repo)) {
    throw "Repository niet gevonden: $Repo"
}

$Repo = [System.IO.Path]::GetFullPath($Repo)
$Evidence = Join-Path $Repo "evidence\06-https"
$ScriptsDirectory = Join-Path $Repo "scripts"
$PkiConfigDirectory = Join-Path $Repo "configs\pki"
$ApacheFilesDirectory = Join-Path $Repo "ansible\files\web\etc"
$DnsZonePath = Join-Path $Repo "ansible\files\dns\etc\cybersec.internal"
$WebPlaybookPath = Join-Path $Repo "ansible\webserver.yml"
$HttpdSourcePath = Join-Path $Repo "ansible\files\web\etc\httpd.conf"
$FirewallPath = Join-Path $Repo "configs\firewall\companyrouter.nft"
$GitIgnorePath = Join-Path $Repo ".gitignore"
$PrivateDirectory = Join-Path $HOME "CSA-Lab6-Private"
$WorkDir = Join-Path $env:TEMP ("csa-lab6-{0}" -f ([guid]::NewGuid().ToString("N")))
$script:WorkDir = $WorkDir

$Tls12ConfigPath = Join-Path $ApacheFilesDirectory "lab6-https-tls12.conf"
$Tls13ConfigPath = Join-Path $ApacheFilesDirectory "lab6-https-tls13.conf"
$OpenSslConfigPath = Join-Path $PkiConfigDirectory "webserver.cnf"
$ClockEvidencePath = Join-Path $Evidence "01-clock-synchronization.txt"
$BuildLogPath = Join-Path $Evidence "98-build-transcript.txt"
$FinalVerificationPath = Join-Path $Evidence "99-final-verification.txt"

New-Item -ItemType Directory -Path $Evidence, $ScriptsDirectory, $PkiConfigDirectory, $ApacheFilesDirectory, $PrivateDirectory, $WorkDir -Force | Out-Null
Set-Location $Repo

Start-Transcript -Path $BuildLogPath -Force | Out-Null
$TranscriptStarted = $true

try {
    Write-Heading "CSA LAB 6 - CA, HTTPS, TLS 1.2/1.3 EN WIRESHARK-BEWIJS"
    Write-Host "Script     : $ScriptVersion"
    Write-Host "Repository : $Repo"
    Write-Host "Evidence   : $Evidence"
    Write-Host "Privéfiles : $PrivateDirectory" -ForegroundColor Magenta

    Write-Heading "1. Repositorybestanden voorbereiden"

    if ($PSCommandPath) {
        $TargetScriptPath = Join-Path $ScriptsDirectory "lab6-https.ps1"
        $SourceFullPath = [System.IO.Path]::GetFullPath($PSCommandPath)
        $TargetFullPath = [System.IO.Path]::GetFullPath($TargetScriptPath)

        if ($SourceFullPath -ne $TargetFullPath) {
            Copy-Item -LiteralPath $SourceFullPath -Destination $TargetFullPath -Force
            Write-Host "Script gekopieerd naar scripts\lab6-https.ps1"
        }
    }

    $WebOpenSslConfig = @'
[ req ]
default_bits       = 2048
prompt             = no
default_md         = sha256
req_extensions     = req_ext
distinguished_name = dn

[ dn ]
C  = BE
ST = Oost-Vlaanderen
L  = Aalst
O  = CSA Lab
OU = Lab 6
CN = cybersec.internal

[ req_ext ]
subjectAltName = @alt_names

[ server_cert ]
subjectAltName = @alt_names
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer

[ alt_names ]
DNS.1 = cybersec.internal
DNS.2 = www.cybersec.internal
DNS.3 = services.cybersec.internal
IP.1  = 172.30.0.10
'@
    Set-Utf8NoBomFile -Path $OpenSslConfigPath -Content (($WebOpenSslConfig.TrimEnd()) + "`n")

    $Tls12Config = @'
# CSA Lab 6 - bewust onveilige TLS 1.2-demonstratie.
# Eindtoestand na het script is TLS 1.3; dit bestand blijft als reproduceerbaar bewijs.
Listen 443 https
SSLSessionCache none

<VirtualHost *:443>
    ServerName www.cybersec.internal
    ServerAlias cybersec.internal
    DocumentRoot "/var/www/html"

    SSLEngine on
    SSLCertificateFile "/etc/pki/tls/certs/csa-webserver.crt"
    SSLCertificateKeyFile "/etc/pki/tls/private/csa-webserver.key"
    SSLCACertificateFile "/etc/pki/tls/certs/csa-lab-root-ca.crt"

    SSLProtocol -all +TLSv1.2
    SSLCipherSuite "AES256-SHA:@SECLEVEL=1"
    SSLHonorCipherOrder on
    SSLSessionTickets off
    SSLCompression off

    ProxyPassInherit On
    ProxyPreserveHost On

    ErrorLog "logs/lab6_tls12_error_log"
    CustomLog "logs/lab6_tls12_access_log" combined
</VirtualHost>

<VirtualHost *:443>
    ServerName services.cybersec.internal

    SSLEngine on
    SSLCertificateFile "/etc/pki/tls/certs/csa-webserver.crt"
    SSLCertificateKeyFile "/etc/pki/tls/private/csa-webserver.key"
    SSLCACertificateFile "/etc/pki/tls/certs/csa-lab-root-ca.crt"

    SSLProtocol -all +TLSv1.2
    SSLCipherSuite "AES256-SHA:@SECLEVEL=1"
    SSLHonorCipherOrder on
    SSLSessionTickets off
    SSLCompression off

    ProxyPassInherit Off
    ProxyPreserveHost On
    ProxyPass "/" "http://127.0.0.1:9200/"
    ProxyPassReverse "/" "http://127.0.0.1:9200/"

    ErrorLog "logs/lab6_services_tls12_error_log"
    CustomLog "logs/lab6_services_tls12_access_log" combined
</VirtualHost>
'@
    Set-Utf8NoBomFile -Path $Tls12ConfigPath -Content (($Tls12Config.TrimEnd()) + "`n")

    $Tls13Config = @'
# CSA Lab 6 - veilige eindconfiguratie met uitsluitend TLS 1.3.
Listen 443 https
SSLSessionCache "shmcb:/run/httpd/sslcache(512000)"
SSLSessionCacheTimeout 300

<VirtualHost *:443>
    ServerName www.cybersec.internal
    ServerAlias cybersec.internal
    DocumentRoot "/var/www/html"

    SSLEngine on
    SSLCertificateFile "/etc/pki/tls/certs/csa-webserver.crt"
    SSLCertificateKeyFile "/etc/pki/tls/private/csa-webserver.key"
    SSLCACertificateFile "/etc/pki/tls/certs/csa-lab-root-ca.crt"

    SSLProtocol -all +TLSv1.3
    SSLCipherSuite TLSv1.3 "TLS_AES_256_GCM_SHA384"
    SSLSessionTickets off
    SSLCompression off

    ProxyPassInherit On
    ProxyPreserveHost On

    ErrorLog "logs/lab6_tls13_error_log"
    CustomLog "logs/lab6_tls13_access_log" combined
</VirtualHost>

<VirtualHost *:443>
    ServerName services.cybersec.internal

    SSLEngine on
    SSLCertificateFile "/etc/pki/tls/certs/csa-webserver.crt"
    SSLCertificateKeyFile "/etc/pki/tls/private/csa-webserver.key"
    SSLCACertificateFile "/etc/pki/tls/certs/csa-lab-root-ca.crt"

    SSLProtocol -all +TLSv1.3
    SSLCipherSuite TLSv1.3 "TLS_AES_256_GCM_SHA384"
    SSLSessionTickets off
    SSLCompression off

    ProxyPassInherit Off
    ProxyPreserveHost On
    ProxyPass "/" "http://127.0.0.1:9200/"
    ProxyPassReverse "/" "http://127.0.0.1:9200/"

    ErrorLog "logs/lab6_services_tls13_error_log"
    CustomLog "logs/lab6_services_tls13_access_log" combined
</VirtualHost>
'@
    Set-Utf8NoBomFile -Path $Tls13ConfigPath -Content (($Tls13Config.TrimEnd()) + "`n")

    if (-not (Test-Path -LiteralPath $WebPlaybookPath)) {
        throw "Ansible-playbook niet gevonden: $WebPlaybookPath"
    }

    $WebPlaybook = [System.IO.File]::ReadAllText($WebPlaybookPath)
    if ($WebPlaybook -notmatch '(?m)^\s*-\s+mod_ssl\s*$') {
        $UpdatedLines = @()
        foreach ($Line in ($WebPlaybook -split "`r?`n")) {
            $UpdatedLines += $Line
            if ($Line -match '^\s*-\s+httpd\s*$') {
                $Indent = ([regex]::Match($Line, '^\s*')).Value
                $UpdatedLines += ($Indent + '- mod_ssl')
            }
        }
        Set-Utf8NoBomFile -Path $WebPlaybookPath -Content ((($UpdatedLines -join "`n").TrimEnd()) + "`n")
        Write-Host "mod_ssl toegevoegd aan ansible\webserver.yml"
    }

    if (-not (Test-Path -LiteralPath $HttpdSourcePath)) {
        throw "Apache-bronconfiguratie niet gevonden: $HttpdSourcePath"
    }

    $HttpdSource = [System.IO.File]::ReadAllText($HttpdSourcePath)
    $FixedHttpdSource = $HttpdSource.Replace(
        'ProxyPassReverse "/aaa" "http://localhost:8000/"',
        'ProxyPassReverse "/cmd" "http://localhost:8000/"'
    )
    if ($FixedHttpdSource -ne $HttpdSource) {
        Set-Utf8NoBomFile -Path $HttpdSourcePath -Content $FixedHttpdSource
        Write-Host "ProxyPassReverse /aaa gecorrigeerd naar /cmd"
    }

    if (-not (Test-Path -LiteralPath $FirewallPath)) {
        throw "Firewallbestand niet gevonden: $FirewallPath"
    }

    $FirewallContent = [System.IO.File]::ReadAllText($FirewallPath)
    $FirewallContent = $FirewallContent.Replace(
        'ip daddr 172.30.0.10 tcp dport 80 accept',
        'ip daddr 172.30.0.10 tcp dport { 80, 443 } accept'
    )

    if ($FirewallContent -notmatch 'ip daddr\s+172\.30\.0\.4\s+udp dport 53') {
        $SshForwardRule = '        iifname "eth1" oifname "eth2" ip saddr 192.168.62.254 tcp dport 22 accept'
        $DnsForwardRules = @'
        iifname "eth1" oifname "eth2" ip saddr 192.168.62.254 ip daddr 172.30.0.4 udp dport 53 accept
        iifname "eth1" oifname "eth2" ip saddr 192.168.62.254 ip daddr 172.30.0.4 tcp dport 53 accept
'@
        if (-not $FirewallContent.Contains($SshForwardRule)) {
            throw "Ankerregel voor de isprouter werd niet in companyrouter.nft gevonden."
        }
        $FirewallContent = $FirewallContent.Replace(
            $SshForwardRule,
            $SshForwardRule + "`n`n        # isprouter mag de interne autoritatieve DNS-server raadplegen.`n" + $DnsForwardRules.TrimEnd()
        )
    }

    if ($FirewallContent -notmatch 'tcp dport\s*\{\s*80\s*,\s*443\s*\}') {
        throw "Poort 443 kon niet veilig aan companyrouter.nft worden toegevoegd."
    }
    if (($FirewallContent -notmatch 'ip daddr\s+172\.30\.0\.4\s+udp dport 53') -or
        ($FirewallContent -notmatch 'ip daddr\s+172\.30\.0\.4\s+tcp dport 53')) {
        throw "De DNS-forwardregels voor isprouter konden niet worden toegevoegd."
    }
    Set-Utf8NoBomFile -Path $FirewallPath -Content (($FirewallContent.TrimEnd()) + "`n")

    if (-not (Test-Path -LiteralPath $DnsZonePath)) {
        throw "DNS-zonebestand niet gevonden: $DnsZonePath"
    }

    $ZoneOriginal = [System.IO.File]::ReadAllText($DnsZonePath)
    $ZoneOutputLines = @()
    foreach ($Line in ($ZoneOriginal -split "`r?`n")) {
        if (($Line -match '^\s*services\s+IN\s+A\s+') -or
            ($Line -match '^\s*@\s+IN\s+A\s+')) {
            continue
        }

        if (($Line -match 'in-addr\.arpa') -and ($Line -notmatch '^\s*;')) {
            $Line = '; ' + $Line
        }

        $ZoneOutputLines += $Line
        if ($Line -match '^\s*www\s+IN\s+A\s+172\.30\.0\.10\s*$') {
            $ZoneOutputLines += '@        IN A    172.30.0.10'
            $ZoneOutputLines += 'services IN A    172.30.0.10'
        }
    }

    $ZoneContent = (($ZoneOutputLines -join "`n").TrimEnd()) + "`n"
    $SerialMatch = [regex]::Match(
        $ZoneContent,
        '(?m)^(?<indent>\s*)(?<serial>\d+)(?<suffix>\s*;\s*serial.*)$'
    )
    if (-not $SerialMatch.Success) {
        throw "SOA-serial niet gevonden in het DNS-zonebestand."
    }

    $CurrentSerial = [long]$SerialMatch.Groups['serial'].Value
    $DateSerial = [long]((Get-Date -Format 'yyyyMMdd') + '01')
    $NewSerial = [Math]::Max(($CurrentSerial + 1), $DateSerial)
    $NewSerialLine = $SerialMatch.Groups['indent'].Value + $NewSerial.ToString() + $SerialMatch.Groups['suffix'].Value
    $ZoneContent = $ZoneContent.Remove($SerialMatch.Index, $SerialMatch.Length).Insert($SerialMatch.Index, $NewSerialLine)
    Set-Utf8NoBomFile -Path $DnsZonePath -Content $ZoneContent
    Write-Host "DNS-records cybersec.internal en services.cybersec.internal toegevoegd; serial = $NewSerial"

    $GitIgnore = if (Test-Path -LiteralPath $GitIgnorePath) {
        [System.IO.File]::ReadAllText($GitIgnorePath)
    }
    else {
        ""
    }

    if ($GitIgnore -notmatch '(?m)^evidence/06-https/private/$') {
        $GitIgnore = $GitIgnore.TrimEnd() + @'

# CSA Lab 6: nooit private sleutels of TLS-sessiegeheimen committen
evidence/06-https/private/
*.keylog
sslkeys.log
'@
        Set-Utf8NoBomFile -Path $GitIgnorePath -Content (($GitIgnore.TrimEnd()) + "`n")
    }

    $EvidenceReadme = @'
# Lab 6 - CA en HTTPS

## Uitgevoerde onderdelen

- Eigen root-CA op `isprouter` (`192.168.62.254`).
- RSA-serverkey en CSR op `web` (`172.30.0.10`).
- SANs: `cybersec.internal`, `www.cybersec.internal`, `services.cybersec.internal` en `172.30.0.10`.
- Apache HTTPS met behoud van `/cmd`, `/assets`, `/exec` en `/services`.
- Extra virtual host `https://services.cybersec.internal/`.
- TLS 1.2-demonstratie met statische RSA-key-exchange (`AES256-SHA`).
- Veilige eindtoestand: uitsluitend TLS 1.3 met `TLS_AES_256_GCM_SHA384`.

## Wireshark - TLS 1.2

Open `10-tls12-rsa.pcap` en configureer onder **Preferences > Protocols > TLS > RSA keys list**:

- IP: `172.30.0.10`
- Port: `443`
- Protocol: `http`
- Key file: `__PRIVATE_DIR__\webserver.key`

Na herladen toont de filter `http` de ontsleutelde HTTP-inhoud. Dit werkt omdat de demo statische RSA-key-exchange gebruikt en geen Perfect Forward Secrecy heeft.

## Wireshark - TLS 1.3

De server-private-key alleen ontsleutelt `20-tls13-pfs.pcap` niet. Configureer in **Preferences > Protocols > TLS** bij **(Pre)-Master-Secret log filename**:

`__PRIVATE_DIR__\tls13-sslkeys.log`

Daarna kan Wireshark de TLS 1.3-sessie ontsleutelen. Het keylogbestand vereist toegang tot het client-endpoint en hoort nooit in Git.

## Veiligheidsgrens

De CA-private-key blijft uitsluitend op `isprouter` in `/etc/csa-ca/private/ca.key`. Alleen de publiek deelbare CA- en servercertificaten staan in deze evidence-map. De tijdelijk geëxporteerde webserver-private-key en TLS-keylog staan buiten de repository in `__PRIVATE_DIR__`.
'@
    $EvidenceReadme = $EvidenceReadme.Replace('__PRIVATE_DIR__', $PrivateDirectory)
    Set-Utf8NoBomFile -Path (Join-Path $Evidence "README.md") -Content (($EvidenceReadme.TrimEnd()) + "`n")

    $PrivateReadme = @"
CSA Lab 6 private evidence
==========================

webserver.key
  Alleen nodig om de bewust onveilige TLS 1.2-capture in Wireshark te ontsleutelen.

tls13-sslkeys.log
  Client-side TLS-sessiegeheimen voor de TLS 1.3-capture.

Deze map staat buiten Git. Deel of commit deze bestanden niet.
De CA-private-key wordt niet naar deze computer gekopieerd en blijft op isprouter.
"@
    Set-Utf8NoBomFile -Path (Join-Path $PrivateDirectory "README.txt") -Content $PrivateReadme

    Write-Heading "2. Bereikbaarheid van de vereiste nodes controleren"
    Invoke-Checked "Vagrant-status" { & vagrant status }
    foreach ($Node in @('isprouter', 'companyrouter', 'dns', 'web', 'employee')) {
        Invoke-Checked "SSH naar $Node" { & ssh $Node hostname }
    }

    Write-Heading "2b. VM-klokken synchroniseren voor PKI-validiteit"
    Set-Utf8NoBomFile -Path $ClockEvidencePath -Content ("CSA LAB 6 CLOCK SYNCHRONIZATION`nHost UTC before sync: {0}`n" -f ([DateTimeOffset]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ss.fffZ")))

    $ClockSyncTemplate = @'
#!/bin/sh
set -eu

TARGET_EPOCH='__TARGET_EPOCH__'

echo "Node: $(hostname)"
echo "UTC before: $(date -u '+%Y-%m-%dT%H:%M:%SZ') (epoch $(date -u '+%s'))"
sudo date -u -s "@${TARGET_EPOCH}" >/dev/null
echo "UTC after : $(date -u '+%Y-%m-%dT%H:%M:%SZ') (epoch $(date -u '+%s'))"
'@

    # Set the CA signer first and the webserver last. This prevents the signer
    # from being ahead of the machine that immediately verifies the new cert.
    foreach ($Node in @('isprouter', 'companyrouter', 'dns', 'employee', 'web')) {
        $TargetEpoch = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        $ClockSyncScript = $ClockSyncTemplate.Replace(
            '__TARGET_EPOCH__',
            $TargetEpoch.ToString([System.Globalization.CultureInfo]::InvariantCulture)
        )
        Invoke-NodeScript `
            -Node $Node `
            -Name "synchronize-utc-clock" `
            -Content $ClockSyncScript `
            -CaptureOutputPath $ClockEvidencePath
    }

    Add-Utf8NoBomText -Path $ClockEvidencePath -Content ("Host UTC after sync: {0}`n" -f ([DateTimeOffset]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ss.fffZ")))

    Write-Heading "3. Root-CA aanmaken op isprouter"
    $CreateCaScript = @'
#!/bin/sh
set -eu

CA_KEY='/etc/csa-ca/private/ca.key'
CA_CERT='/etc/csa-ca/certs/ca.crt'
CA_SERIAL='/etc/csa-ca/certs/ca.srl'

sudo apk add --no-cache openssl ca-certificates curl >/dev/null
sudo mkdir -p /etc/csa-ca/private /etc/csa-ca/certs /etc/csa-ca/requests
sudo chmod 0700 /etc/csa-ca/private
sudo chmod 0755 /etc/csa-ca/certs /etc/csa-ca/requests

# The private directory is root-only. Test the key through sudo; otherwise the
# vagrant shell sees a permission failure as "missing" and overwrites the key.
if ! sudo test -s "$CA_KEY"; then
    sudo openssl genrsa -out "$CA_KEY" 4096
fi
sudo chown root:root "$CA_KEY"
sudo chmod 0600 "$CA_KEY"

# A previous interrupted/idempotency-bug run may have retained the old
# certificate while replacing the key. Detect that state and rebuild only the
# public certificate from the current private key. No successful leaf
# certificate can exist before this point in the workflow.
if sudo test -s "$CA_CERT"; then
    KEY_HASH=$(sudo openssl pkey -in "$CA_KEY" -pubout -outform DER 2>/dev/null | sha256sum | awk '{print $1}')
    CERT_HASH=$(sudo openssl x509 -in "$CA_CERT" -pubkey -noout 2>/dev/null | openssl pkey -pubin -outform DER 2>/dev/null | sha256sum | awk '{print $1}')

    if [ "$KEY_HASH" != "$CERT_HASH" ]; then
        STAMP=$(date -u +%Y%m%dT%H%M%SZ)
        BACKUP="${CA_CERT}.mismatch-${STAMP}"
        sudo cp "$CA_CERT" "$BACKUP"
        sudo chmod 0600 "$BACKUP"
        sudo rm -f "$CA_CERT" "$CA_SERIAL" /etc/csa-ca/certs/csa-webserver.crt
        echo "CA key/certificate mismatch hersteld; oud certificaat bewaard als $BACKUP"
    fi
fi

if ! sudo test -s "$CA_CERT"; then
    sudo rm -f "${CA_CERT}.new"
    sudo openssl req -x509 -new -sha256 -days 3650 \
        -key "$CA_KEY" \
        -out "${CA_CERT}.new" \
        -subj '/C=BE/ST=Oost-Vlaanderen/L=Aalst/O=CSA Lab/OU=Lab 6/CN=CSA Lab Root CA' \
        -addext 'basicConstraints=critical,CA:TRUE,pathlen:0' \
        -addext 'keyUsage=critical,keyCertSign,cRLSign' \
        -addext 'subjectKeyIdentifier=hash'
    sudo chown root:root "${CA_CERT}.new"
    sudo chmod 0644 "${CA_CERT}.new"
    sudo mv "${CA_CERT}.new" "$CA_CERT"
fi
sudo chown root:root "$CA_CERT"
sudo chmod 0644 "$CA_CERT"

KEY_HASH=$(sudo openssl pkey -in "$CA_KEY" -pubout -outform DER 2>/dev/null | sha256sum | awk '{print $1}')
CERT_HASH=$(sudo openssl x509 -in "$CA_CERT" -pubkey -noout 2>/dev/null | openssl pkey -pubin -outform DER 2>/dev/null | sha256sum | awk '{print $1}')
[ "$KEY_HASH" = "$CERT_HASH" ]
echo "CA key/certificate public-key hash: $KEY_HASH"

sudo openssl x509 -in "$CA_CERT" \
    -noout -subject -issuer -serial -dates -fingerprint -sha256

sudo cp "$CA_CERT" /tmp/csa-lab-root-ca.crt
sudo chown vagrant:vagrant /tmp/csa-lab-root-ca.crt
sudo chmod 0644 /tmp/csa-lab-root-ca.crt
'@
    Invoke-NodeScript -Node "isprouter" -Name "create-root-ca" -Content $CreateCaScript
    Copy-FromNode -Node "isprouter" -RemotePath "/tmp/csa-lab-root-ca.crt" -LocalPath (Join-Path $Evidence "ca.crt")
    & ssh isprouter "rm -f /tmp/csa-lab-root-ca.crt" 2>$null | Out-Null

    Write-Heading "4. Webserver-key en CSR op web aanmaken"
    Copy-ToNode -Node "web" -LocalPath $OpenSslConfigPath -RemotePath "/tmp/csa-webserver.cnf"

    $CreateWebCsrScript = @'
#!/bin/sh
set -eu

sudo dnf -y install mod_ssl openssl curl >/dev/null
sudo mkdir -p /etc/pki/tls/private /etc/pki/tls/certs
sudo chmod 0700 /etc/pki/tls/private
sudo install -m 0644 /tmp/csa-webserver.cnf /etc/pki/tls/csa-webserver.cnf

# The directory is root-only, so perform the existence test through sudo.
if ! sudo test -s /etc/pki/tls/private/csa-webserver.key; then
    sudo openssl genrsa -out /etc/pki/tls/private/csa-webserver.key 2048
fi
sudo chown root:root /etc/pki/tls/private/csa-webserver.key
sudo chmod 0600 /etc/pki/tls/private/csa-webserver.key

sudo openssl req -new \
    -key /etc/pki/tls/private/csa-webserver.key \
    -out /etc/pki/tls/csa-webserver.csr \
    -config /etc/pki/tls/csa-webserver.cnf

sudo openssl req -in /etc/pki/tls/csa-webserver.csr -noout -verify -subject
sudo openssl req -in /etc/pki/tls/csa-webserver.csr -noout -text | sed -n '/Subject Alternative Name/,+1p'

sudo cp /etc/pki/tls/csa-webserver.csr /tmp/csa-webserver.csr
sudo chown vagrant:vagrant /tmp/csa-webserver.csr
sudo chmod 0644 /tmp/csa-webserver.csr
'@
    Invoke-NodeScript -Node "web" -Name "create-web-csr" -Content $CreateWebCsrScript

    $LocalCsrPath = Join-Path $WorkDir "csa-webserver.csr"
    Copy-FromNode -Node "web" -RemotePath "/tmp/csa-webserver.csr" -LocalPath $LocalCsrPath
    Copy-Item -LiteralPath $LocalCsrPath -Destination (Join-Path $Evidence "webserver.csr") -Force
    & ssh web "rm -f /tmp/csa-webserver.csr" 2>$null | Out-Null

    Write-Heading "5. CSR door de CA laten ondertekenen"
    Copy-ToNode -Node "isprouter" -LocalPath $LocalCsrPath -RemotePath "/tmp/csa-webserver.csr"
    Copy-ToNode -Node "isprouter" -LocalPath $OpenSslConfigPath -RemotePath "/tmp/csa-webserver.cnf"

    $SignCertificateScript = @'
#!/bin/sh
set -eu

CSR='/etc/csa-ca/requests/csa-webserver.csr'
CERT='/etc/csa-ca/certs/csa-webserver.crt'
CA_CERT='/etc/csa-ca/certs/ca.crt'
CA_KEY='/etc/csa-ca/private/ca.key'

sudo cp /tmp/csa-webserver.csr "$CSR"
sudo chmod 0644 "$CSR"

echo "CA signer UTC: $(date -u '+%Y-%m-%dT%H:%M:%SZ') (epoch $(date -u '+%s'))"

CSR_HASH=$(sudo openssl req -in "$CSR" -pubkey -noout 2>/dev/null | openssl pkey -pubin -outform DER 2>/dev/null | sha256sum | awk '{print $1}')
REUSE_CERT=0

if sudo test -s "$CERT"; then
    CERT_HASH=$(sudo openssl x509 -in "$CERT" -pubkey -noout 2>/dev/null | openssl pkey -pubin -outform DER 2>/dev/null | sha256sum | awk '{print $1}')

    if [ "$CSR_HASH" = "$CERT_HASH" ] && \
       sudo openssl verify -no_check_time -CAfile "$CA_CERT" "$CERT" >/dev/null 2>&1 && \
       sudo openssl x509 -in "$CERT" -noout -checkend 86400 >/dev/null 2>&1 && \
       sudo openssl x509 -in "$CERT" -noout -checkhost www.cybersec.internal >/dev/null 2>&1 && \
       sudo openssl x509 -in "$CERT" -noout -checkhost services.cybersec.internal >/dev/null 2>&1 && \
       sudo openssl x509 -in "$CERT" -noout -checkip 172.30.0.10 >/dev/null 2>&1; then
        REUSE_CERT=1
    fi
fi

if [ "$REUSE_CERT" -eq 1 ]; then
    echo 'Bestaand, geldig servercertificaat hergebruikt; geen nieuwe notBefore-tijd aangemaakt.'
else
    sudo rm -f "${CERT}.new"
    sudo openssl x509 -req \
        -in "$CSR" \
        -CA "$CA_CERT" \
        -CAkey "$CA_KEY" \
        -CAcreateserial \
        -out "${CERT}.new" \
        -days 825 \
        -sha256 \
        -extensions server_cert \
        -extfile /tmp/csa-webserver.cnf

    sudo chown root:root "${CERT}.new"
    sudo chmod 0644 "${CERT}.new"
    sudo mv "${CERT}.new" "$CERT"
    echo 'Nieuw servercertificaat uitgegeven.'
fi

sudo chmod 0644 "$CERT"
sudo openssl verify -CAfile "$CA_CERT" "$CERT"
sudo openssl x509 -in "$CERT" -noout -checkhost www.cybersec.internal
sudo openssl x509 -in "$CERT" -noout -checkhost services.cybersec.internal
sudo openssl x509 -in "$CERT" -noout -checkip 172.30.0.10
sudo openssl x509 -in "$CERT" \
    -noout -subject -issuer -serial -dates -fingerprint -sha256

sudo cp "$CERT" /tmp/csa-webserver.crt
sudo cp "$CA_CERT" /tmp/csa-lab-root-ca.crt
sudo chown vagrant:vagrant /tmp/csa-webserver.crt /tmp/csa-lab-root-ca.crt
sudo chmod 0644 /tmp/csa-webserver.crt /tmp/csa-lab-root-ca.crt
'@
    Invoke-NodeScript -Node "isprouter" -Name "sign-web-certificate" -Content $SignCertificateScript

    $LocalServerCertificate = Join-Path $WorkDir "csa-webserver.crt"
    $LocalCaCertificate = Join-Path $WorkDir "csa-lab-root-ca.crt"
    Copy-FromNode -Node "isprouter" -RemotePath "/tmp/csa-webserver.crt" -LocalPath $LocalServerCertificate
    Copy-FromNode -Node "isprouter" -RemotePath "/tmp/csa-lab-root-ca.crt" -LocalPath $LocalCaCertificate
    Copy-Item -LiteralPath $LocalServerCertificate -Destination (Join-Path $Evidence "webserver.crt") -Force
    Copy-Item -LiteralPath $LocalCaCertificate -Destination (Join-Path $Evidence "ca.crt") -Force
    & ssh isprouter "rm -f /tmp/csa-webserver.crt /tmp/csa-lab-root-ca.crt /tmp/csa-webserver.csr /tmp/csa-webserver.cnf" 2>$null | Out-Null

    Write-Heading "6. Certificaten op web installeren"
    Copy-ToNode -Node "web" -LocalPath $LocalServerCertificate -RemotePath "/tmp/csa-webserver.crt"
    Copy-ToNode -Node "web" -LocalPath $LocalCaCertificate -RemotePath "/tmp/csa-lab-root-ca.crt"

    $InstallWebCertificateScript = @'
#!/bin/sh
set -eu

CA_CERT='/etc/pki/tls/certs/csa-lab-root-ca.crt'
SERVER_CERT='/etc/pki/tls/certs/csa-webserver.crt'
SERVER_KEY='/etc/pki/tls/private/csa-webserver.key'

sudo install -m 0644 /tmp/csa-webserver.crt "$SERVER_CERT"
sudo install -m 0644 /tmp/csa-lab-root-ca.crt "$CA_CERT"
sudo chown root:root "$SERVER_CERT" "$CA_CERT"
sudo chmod 0600 "$SERVER_KEY"

if command -v restorecon >/dev/null 2>&1; then
    sudo restorecon -Rv /etc/pki/tls/certs /etc/pki/tls/private >/dev/null 2>&1 || true
fi

echo "Web UTC       : $(date -u '+%Y-%m-%dT%H:%M:%SZ') (epoch $(date -u '+%s'))"
echo "CA validity   : $(sudo openssl x509 -in "$CA_CERT" -noout -startdate -enddate | tr '\n' ' ')"
echo "Leaf validity : $(sudo openssl x509 -in "$SERVER_CERT" -noout -startdate -enddate | tr '\n' ' ')"

# Even after explicit clock convergence, sub-second scheduling can make a newly
# issued certificate appear marginally in the future. Retry briefly, but emit
# full timestamps and fail clearly if a real clock problem remains.
ATTEMPT=1
while :; do
    if VERIFY_OUTPUT=$(sudo openssl verify -CAfile "$CA_CERT" "$SERVER_CERT" 2>&1); then
        printf '%s\n' "$VERIFY_OUTPUT"
        break
    fi

    if [ "$ATTEMPT" -ge 30 ]; then
        printf '%s\n' "$VERIFY_OUTPUT" >&2
        echo "Certificate verification bleef mislukken na $ATTEMPT pogingen." >&2
        echo "Web UTC: $(date -u '+%Y-%m-%dT%H:%M:%SZ') (epoch $(date -u '+%s'))" >&2
        sudo openssl x509 -in "$CA_CERT" -noout -dates >&2
        sudo openssl x509 -in "$SERVER_CERT" -noout -dates >&2
        exit 2
    fi

    if [ "$ATTEMPT" -eq 1 ]; then
        echo 'Certificaat is nog net niet geldig; korte verificatie-retry gestart.'
    fi
    sleep 1
    ATTEMPT=$((ATTEMPT + 1))
done

KEY_HASH=$(sudo openssl pkey -in "$SERVER_KEY" -pubout 2>/dev/null | openssl pkey -pubin -outform DER 2>/dev/null | sha256sum | awk '{print $1}')
CERT_HASH=$(sudo openssl x509 -in "$SERVER_CERT" -pubkey -noout 2>/dev/null | openssl pkey -pubin -outform DER 2>/dev/null | sha256sum | awk '{print $1}')
[ "$KEY_HASH" = "$CERT_HASH" ]
echo "Private key en servercertificaat horen bij elkaar: $KEY_HASH"
'@
    Invoke-NodeScript -Node "web" -Name "install-web-certificate" -Content $InstallWebCertificateScript

    Write-Heading "7. DNS-record en firewallpoort 443 live toepassen"
    Copy-ToNode -Node "dns" -LocalPath $DnsZonePath -RemotePath "/tmp/cybersec.internal"
    $ApplyDnsScript = @'
#!/bin/sh
set -eu

sudo named-checkzone cybersec.internal /tmp/cybersec.internal
sudo cp /tmp/cybersec.internal /var/bind/cybersec.internal
sudo chown root:root /var/bind/cybersec.internal
sudo chmod 0644 /var/bind/cybersec.internal
sudo rc-service named restart
sudo rc-service named status

dig @127.0.0.1 cybersec.internal A +noall +answer
dig @127.0.0.1 www.cybersec.internal A +noall +answer
dig @127.0.0.1 services.cybersec.internal A +noall +answer
'@
    Invoke-NodeScript -Node "dns" -Name "apply-dns-zone" -Content $ApplyDnsScript

    Copy-ToNode -Node "companyrouter" -LocalPath $FirewallPath -RemotePath "/tmp/companyrouter.nft"
    $ApplyFirewallScript = @'
#!/bin/sh
set -eu

sudo mkdir -p /etc/csa
sudo install -m 0600 /tmp/companyrouter.nft /etc/csa/companyrouter.nft
sudo nft -c -f /etc/csa/companyrouter.nft

cat >/tmp/csa-firewall.service <<'UNIT'
[Unit]
Description=CSA persistent nftables firewall
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/sbin/nft -f /etc/csa/companyrouter.nft
ExecReload=/usr/sbin/nft -f /etc/csa/companyrouter.nft
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT

sudo install -m 0644 /tmp/csa-firewall.service /etc/systemd/system/csa-firewall.service
sudo systemctl daemon-reload
sudo systemctl enable csa-firewall.service >/dev/null
sudo systemctl restart csa-firewall.service
sudo systemctl is-active --quiet csa-firewall.service
sudo nft -n list chain inet csa_firewall forward
sudo nft -n list chain inet csa_firewall forward | grep -E 'dport.*(80|443)'
sudo nft -n list chain inet csa_firewall forward | grep -E '172\.30\.0\.4.*dport 53'
'@
    Invoke-NodeScript -Node "companyrouter" -Name "apply-company-firewall" -Content $ApplyFirewallScript

    $RefreshIspDnsScript = @'
#!/bin/sh
set -eu
sudo rc-service unbound restart
sudo rc-service unbound status
nslookup cybersec.internal 192.168.62.254
nslookup www.cybersec.internal 192.168.62.254
nslookup services.cybersec.internal 192.168.62.254
'@
    Invoke-NodeScript -Node "isprouter" -Name "refresh-unbound" -Content $RefreshIspDnsScript

    Write-Heading "8. Root-CA op employee vertrouwen"
    Copy-ToNode -Node "employee" -LocalPath $LocalCaCertificate -RemotePath "/tmp/csa-lab-root-ca.crt"
    $TrustEmployeeScript = @'
#!/bin/sh
set -eu

sudo apk add --no-cache ca-certificates curl openssl tcpdump bind-tools >/dev/null
sudo mkdir -p /usr/local/share/ca-certificates
sudo cp /tmp/csa-lab-root-ca.crt /usr/local/share/ca-certificates/csa-lab-root-ca.crt
sudo chown root:root /usr/local/share/ca-certificates/csa-lab-root-ca.crt
sudo chmod 0644 /usr/local/share/ca-certificates/csa-lab-root-ca.crt
sudo update-ca-certificates >/dev/null

# De interne DNS-server hoort de primaire resolver van de interne client te zijn.
printf 'nameserver 172.30.0.4\n' | sudo tee /etc/resolv.conf >/dev/null

dig @172.30.0.4 cybersec.internal A +noall +answer
dig @172.30.0.4 www.cybersec.internal A +noall +answer
dig @172.30.0.4 services.cybersec.internal A +noall +answer
'@
    Invoke-NodeScript -Node "employee" -Name "trust-root-ca" -Content $TrustEmployeeScript

    # De losse Debian/Browser-VM `red` staat niet in de Vagrantfile, maar was in de baseline bereikbaar.
    # Daarom wordt ze best-effort voorzien van dezelfde root-CA zonder de kernopstelling ervan afhankelijk te maken.
    $global:LASTEXITCODE = 0
    & ssh "-o" "ConnectTimeout=5" "red" "true" 2>$null | Out-Null
    $RedAvailable = ($LASTEXITCODE -eq 0)
    if ($RedAvailable) {
        try {
            $RedTargetEpoch = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
            $RedClockSyncScript = $ClockSyncTemplate.Replace(
                '__TARGET_EPOCH__',
                $RedTargetEpoch.ToString([System.Globalization.CultureInfo]::InvariantCulture)
            )
            Invoke-NodeScript `
                -Node "red" `
                -Name "synchronize-utc-clock-browser-vm" `
                -Content $RedClockSyncScript `
                -CaptureOutputPath $ClockEvidencePath

            Copy-ToNode -Node "red" -LocalPath $LocalCaCertificate -RemotePath "/tmp/csa-lab-root-ca.crt"
            $TrustRedScript = @'
#!/bin/sh
set -eu

sudo mkdir -p /usr/local/share/ca-certificates
sudo cp /tmp/csa-lab-root-ca.crt /usr/local/share/ca-certificates/csa-lab-root-ca.crt
sudo chown root:root /usr/local/share/ca-certificates/csa-lab-root-ca.crt
sudo chmod 0644 /usr/local/share/ca-certificates/csa-lab-root-ca.crt
sudo update-ca-certificates >/dev/null

getent hosts cybersec.internal
getent hosts www.cybersec.internal
getent hosts services.cybersec.internal
'@
            Invoke-NodeScript -Node "red" -Name "trust-root-ca-browser-vm" -Content $TrustRedScript
            Write-Host "Root-CA ook in de OS-truststore van red geïnstalleerd." -ForegroundColor Green
        }
        catch {
            Write-Warning "De optionele Browser-VM red kon niet volledig worden bijgewerkt: $($_.Exception.Message)"
        }
    }
    else {
        Write-Warning "Optionele Browser-VM red is niet bereikbaar; ca.crt staat klaar in evidence\06-https voor handmatige import."
    }

    Write-Heading "9. Bewust onveilige TLS 1.2/RSA-demonstratie"
    Apply-ApacheConfiguration -LocalConfig $Tls12ConfigPath -Label "tls12"

    $Tls12HandshakeScript = @'
#!/bin/sh
set -eu

CA=/usr/local/share/ca-certificates/csa-lab-root-ca.crt
SERVER=172.30.0.10

echo '=== TLS 1.2 STATIC RSA HANDSHAKE ==='
timeout 12 openssl s_client \
    -connect "$SERVER:443" \
    -servername www.cybersec.internal \
    -tls1_2 \
    -cipher 'AES256-SHA:@SECLEVEL=1' \
    -CAfile "$CA" \
    -verify_return_error \
    -brief </dev/null 2>&1

echo
echo '=== HTTPS HEADERS ==='
curl --noproxy '*' \
    --resolve "www.cybersec.internal:443:$SERVER" \
    --cacert "$CA" \
    --tlsv1.2 --tls-max 1.2 \
    --ciphers 'AES256-SHA:@SECLEVEL=1' \
    --silent --show-error \
    --dump-header - \
    --output /dev/null \
    https://www.cybersec.internal/
'@
    Invoke-NodeScript -Node "employee" -Name "verify-tls12-rsa" -Content $Tls12HandshakeScript -CaptureOutputPath (Join-Path $Evidence "10-tls12-handshake.txt")

    if (-not $SkipPacketCaptures) {
        $Tls12CaptureScript = @'
#!/bin/sh
set -eu

CA=/usr/local/share/ca-certificates/csa-lab-root-ca.crt
SERVER=172.30.0.10
IFACE=$(ip route get "$SERVER" | awk '{for (i=1; i<=NF; i++) if ($i=="dev") {print $(i+1); exit}}')
[ -n "$IFACE" ]

sudo rm -f /tmp/lab6-tls12.pcap /tmp/lab6-tls12-headers.txt /tmp/lab6-tls12-body.html
sudo tcpdump -i "$IFACE" -U -s 0 \
    -w /tmp/lab6-tls12.pcap \
    "host $SERVER and tcp port 443" >/tmp/lab6-tls12-tcpdump.log 2>&1 &
CAPTURE_PID=$!

cleanup() {
    sudo kill -INT "$CAPTURE_PID" 2>/dev/null || true
    wait "$CAPTURE_PID" 2>/dev/null || true
}
trap cleanup EXIT INT TERM
sleep 2

curl --noproxy '*' \
    --resolve "www.cybersec.internal:443:$SERVER" \
    --cacert "$CA" \
    --tlsv1.2 --tls-max 1.2 \
    --ciphers 'AES256-SHA:@SECLEVEL=1' \
    --silent --show-error \
    --dump-header /tmp/lab6-tls12-headers.txt \
    --output /tmp/lab6-tls12-body.html \
    https://www.cybersec.internal/

sleep 2
cleanup
trap - EXIT INT TERM

sudo chown vagrant:vagrant \
    /tmp/lab6-tls12.pcap \
    /tmp/lab6-tls12-headers.txt \
    /tmp/lab6-tls12-body.html
sudo chmod 0644 \
    /tmp/lab6-tls12.pcap \
    /tmp/lab6-tls12-headers.txt \
    /tmp/lab6-tls12-body.html

test -s /tmp/lab6-tls12.pcap
test -s /tmp/lab6-tls12-headers.txt
ls -lh /tmp/lab6-tls12.pcap /tmp/lab6-tls12-headers.txt
'@
        Invoke-NodeScript -Node "employee" -Name "capture-tls12-rsa" -Content $Tls12CaptureScript
        Copy-FromNode -Node "employee" -RemotePath "/tmp/lab6-tls12.pcap" -LocalPath (Join-Path $Evidence "10-tls12-rsa.pcap")
        Copy-FromNode -Node "employee" -RemotePath "/tmp/lab6-tls12-headers.txt" -LocalPath (Join-Path $Evidence "10-tls12-headers.txt")
    }

    $ExportWebKeyScript = @'
#!/bin/sh
set -eu
sudo cp /etc/pki/tls/private/csa-webserver.key /tmp/csa-lab6-webserver.key
sudo chown vagrant:vagrant /tmp/csa-lab6-webserver.key
sudo chmod 0600 /tmp/csa-lab6-webserver.key
'@
    Invoke-NodeScript -Node "web" -Name "export-web-key-for-tls12-demo" -Content $ExportWebKeyScript
    $PrivateWebKeyPath = Join-Path $PrivateDirectory "webserver.key"
    Copy-FromNode -Node "web" -RemotePath "/tmp/csa-lab6-webserver.key" -LocalPath $PrivateWebKeyPath
    & ssh web "rm -f /tmp/csa-lab6-webserver.key" 2>$null | Out-Null
    Write-Host "TLS 1.2-demo-key buiten Git opgeslagen: $PrivateWebKeyPath" -ForegroundColor Magenta
    Write-Host "SHA256: $((Get-FileHash -Algorithm SHA256 -LiteralPath $PrivateWebKeyPath).Hash)"

    Write-Heading "10. Veilige TLS 1.3-eindconfiguratie"
    Apply-ApacheConfiguration -LocalConfig $Tls13ConfigPath -Label "tls13"

    $Tls13HandshakeScript = @'
#!/bin/sh
set -eu

CA=/usr/local/share/ca-certificates/csa-lab-root-ca.crt
SERVER=172.30.0.10

echo '=== TLS 1.3 HANDSHAKE ==='
timeout 12 openssl s_client \
    -connect "$SERVER:443" \
    -servername www.cybersec.internal \
    -tls1_3 \
    -ciphersuites TLS_AES_256_GCM_SHA384 \
    -CAfile "$CA" \
    -verify_return_error \
    -brief </dev/null 2>&1

echo
echo '=== TLS 1.2 SHOULD NOW FAIL ==='
set +e
TLS12_OUTPUT=$(timeout 8 openssl s_client \
    -connect "$SERVER:443" \
    -servername www.cybersec.internal \
    -tls1_2 \
    -cipher 'AES256-SHA:@SECLEVEL=1' \
    -CAfile "$CA" \
    -brief </dev/null 2>&1)
TLS12_RC=$?
set -e
printf '%s\n' "$TLS12_OUTPUT"
if printf '%s\n' "$TLS12_OUTPUT" | grep -q 'CONNECTION ESTABLISHED'; then
    echo 'FOUT: TLS 1.2 werd nog geaccepteerd.' >&2
    exit 1
fi
echo "Verwacht resultaat: TLS 1.2 geweigerd (exitcode $TLS12_RC)."
'@
    Invoke-NodeScript -Node "employee" -Name "verify-final-tls13" -Content $Tls13HandshakeScript -CaptureOutputPath (Join-Path $Evidence "20-tls13-handshake.txt")

    if (-not $SkipPacketCaptures) {
        $Tls13CaptureScript = @'
#!/bin/sh
set -eu

CA=/usr/local/share/ca-certificates/csa-lab-root-ca.crt
SERVER=172.30.0.10
IFACE=$(ip route get "$SERVER" | awk '{for (i=1; i<=NF; i++) if ($i=="dev") {print $(i+1); exit}}')
[ -n "$IFACE" ]

sudo rm -f \
    /tmp/lab6-tls13.pcap \
    /tmp/lab6-tls13-sslkeys.log \
    /tmp/lab6-tls13-handshake.txt \
    /tmp/lab6-tls13-www-response.txt \
    /tmp/lab6-tls13-services-response.txt \
    /tmp/lab6-tls13-headers.txt

sudo tcpdump -i "$IFACE" -U -s 0 \
    -w /tmp/lab6-tls13.pcap \
    "host $SERVER and tcp port 443" >/tmp/lab6-tls13-tcpdump.log 2>&1 &
CAPTURE_PID=$!

cleanup() {
    sudo kill -INT "$CAPTURE_PID" 2>/dev/null || true
    wait "$CAPTURE_PID" 2>/dev/null || true
}
trap cleanup EXIT INT TERM
sleep 2

printf 'GET / HTTP/1.1\r\nHost: www.cybersec.internal\r\nConnection: close\r\n\r\n' | \
    timeout 15 openssl s_client \
        -connect "$SERVER:443" \
        -servername www.cybersec.internal \
        -tls1_3 \
        -ciphersuites TLS_AES_256_GCM_SHA384 \
        -CAfile "$CA" \
        -verify_return_error \
        -keylogfile /tmp/lab6-tls13-sslkeys.log \
        -quiet \
        >/tmp/lab6-tls13-www-response.txt \
        2>/tmp/lab6-tls13-handshake.txt

printf 'GET / HTTP/1.1\r\nHost: services.cybersec.internal\r\nConnection: close\r\n\r\n' | \
    timeout 15 openssl s_client \
        -connect "$SERVER:443" \
        -servername services.cybersec.internal \
        -tls1_3 \
        -ciphersuites TLS_AES_256_GCM_SHA384 \
        -CAfile "$CA" \
        -verify_return_error \
        -keylogfile /tmp/lab6-tls13-sslkeys.log \
        -quiet \
        >/tmp/lab6-tls13-services-response.txt \
        2>>/tmp/lab6-tls13-handshake.txt

sleep 2
cleanup
trap - EXIT INT TERM

curl --noproxy '*' \
    --resolve "www.cybersec.internal:443:$SERVER" \
    --cacert "$CA" \
    --tlsv1.3 --tls-max 1.3 \
    --silent --show-error \
    --dump-header /tmp/lab6-tls13-headers.txt \
    --output /dev/null \
    https://www.cybersec.internal/

sudo chown vagrant:vagrant \
    /tmp/lab6-tls13.pcap \
    /tmp/lab6-tls13-sslkeys.log \
    /tmp/lab6-tls13-handshake.txt \
    /tmp/lab6-tls13-headers.txt
sudo chmod 0600 /tmp/lab6-tls13-sslkeys.log
sudo chmod 0644 \
    /tmp/lab6-tls13.pcap \
    /tmp/lab6-tls13-handshake.txt \
    /tmp/lab6-tls13-headers.txt

test -s /tmp/lab6-tls13.pcap
test -s /tmp/lab6-tls13-sslkeys.log
test -s /tmp/lab6-tls13-handshake.txt
ls -lh \
    /tmp/lab6-tls13.pcap \
    /tmp/lab6-tls13-sslkeys.log \
    /tmp/lab6-tls13-handshake.txt
'@
        Invoke-NodeScript -Node "employee" -Name "capture-tls13-pfs" -Content $Tls13CaptureScript
        Copy-FromNode -Node "employee" -RemotePath "/tmp/lab6-tls13.pcap" -LocalPath (Join-Path $Evidence "20-tls13-pfs.pcap")
        Copy-FromNode -Node "employee" -RemotePath "/tmp/lab6-tls13-handshake.txt" -LocalPath (Join-Path $Evidence "20-tls13-capture-handshake.txt")
        Copy-FromNode -Node "employee" -RemotePath "/tmp/lab6-tls13-headers.txt" -LocalPath (Join-Path $Evidence "20-tls13-headers.txt")

        $PrivateKeyLogPath = Join-Path $PrivateDirectory "tls13-sslkeys.log"
        Copy-FromNode -Node "employee" -RemotePath "/tmp/lab6-tls13-sslkeys.log" -LocalPath $PrivateKeyLogPath
        & ssh employee "rm -f /tmp/lab6-tls13-sslkeys.log" 2>$null | Out-Null
        Write-Host "TLS 1.3-keylog buiten Git opgeslagen: $PrivateKeyLogPath" -ForegroundColor Magenta
        Write-Host "SHA256: $((Get-FileHash -Algorithm SHA256 -LiteralPath $PrivateKeyLogPath).Hash)"
    }

    Write-Heading "11. Eindverificatie en Git-bewijs"
    Set-Utf8NoBomFile -Path $FinalVerificationPath -Content ("CSA LAB 6 FINAL VERIFICATION`nGenerated: {0}`n" -f (Get-Date -Format o))

    $VerifyWebScript = @'
#!/bin/sh
set -eu

echo '=== WEB: PACKAGES AND MODULES ==='
rpm -q httpd mod_ssl openssl
sudo httpd -M 2>&1 | grep -E 'ssl_module|proxy_module|proxy_http_module|socache_shmcb_module'

echo
echo '=== WEB: CONFIGURATION ==='
sudo httpd -t
sudo httpd -t -D DUMP_VHOSTS 2>&1 || true
sudo grep -nE 'Listen 443|ServerName|ServerAlias|SSLProtocol|SSLCipherSuite|SSLCertificate|ProxyPass' /etc/httpd/conf.d/ssl.conf

echo
echo '=== WEB: LISTENERS ==='
sudo ss -lntp | grep -E '(:80|:443|:8000|:9200)[[:space:]]'

echo
echo '=== WEB: CERTIFICATE ==='
sudo openssl verify -CAfile /etc/pki/tls/certs/csa-lab-root-ca.crt /etc/pki/tls/certs/csa-webserver.crt
sudo openssl x509 -in /etc/pki/tls/certs/csa-webserver.crt -noout -subject -issuer -serial -dates -fingerprint -sha256
sudo openssl x509 -in /etc/pki/tls/certs/csa-webserver.crt -noout -ext subjectAltName
sudo openssl x509 -in /etc/pki/tls/certs/csa-webserver.crt -noout -ext extendedKeyUsage

echo
echo '=== WEB: SERVICES ==='
for SERVICE in httpd insecurewebapp flaskapp; do
    printf '%-20s ' "$SERVICE"
    systemctl is-active "$SERVICE"
done
'@
    Invoke-NodeScript -Node "web" -Name "final-web-verification" -Content $VerifyWebScript -CaptureOutputPath $FinalVerificationPath

    $VerifyEmployeeScript = @'
#!/bin/sh
set -eu

CA=/usr/local/share/ca-certificates/csa-lab-root-ca.crt
SERVER=172.30.0.10

echo '=== EMPLOYEE: DNS ==='
dig @172.30.0.4 cybersec.internal A +noall +answer
dig @172.30.0.4 www.cybersec.internal A +noall +answer
dig @172.30.0.4 services.cybersec.internal A +noall +answer

echo
echo '=== EMPLOYEE: TRUSTED HTTPS ENDPOINTS ==='
for URL in \
    https://www.cybersec.internal/ \
    https://cybersec.internal/ \
    https://www.cybersec.internal/cmd \
    https://www.cybersec.internal/services \
    https://services.cybersec.internal/
do
    CODE=$(curl --noproxy '*' --silent --show-error --output /dev/null --write-out '%{http_code}' "$URL")
    printf '%-52s HTTP %s\n' "$URL" "$CODE"
    [ "$CODE" = '200' ]
done

echo
echo '=== EMPLOYEE: TLS 1.3 NEGOTIATION ==='
timeout 12 openssl s_client \
    -connect "$SERVER:443" \
    -servername www.cybersec.internal \
    -tls1_3 \
    -ciphersuites TLS_AES_256_GCM_SHA384 \
    -CAfile "$CA" \
    -verify_return_error \
    -brief </dev/null 2>&1

echo
echo '=== EMPLOYEE: TLS 1.2 REJECTION ==='
set +e
TLS12_OUTPUT=$(timeout 8 openssl s_client \
    -connect "$SERVER:443" \
    -servername www.cybersec.internal \
    -tls1_2 \
    -cipher 'AES256-SHA:@SECLEVEL=1' \
    -CAfile "$CA" \
    -brief </dev/null 2>&1)
set -e
printf '%s\n' "$TLS12_OUTPUT"
if printf '%s\n' "$TLS12_OUTPUT" | grep -q 'CONNECTION ESTABLISHED'; then
    exit 1
fi
echo 'TLS 1.2 is correct geweigerd in de eindconfiguratie.'
'@
    Invoke-NodeScript -Node "employee" -Name "final-client-verification" -Content $VerifyEmployeeScript -CaptureOutputPath $FinalVerificationPath

    if ($RedAvailable) {
        try {
            $VerifyRedScript = @'
#!/bin/sh
set -eu

echo '=== RED/BROWSER VM: SYSTEM TRUST AND HTTPS ==='
for URL in \
    https://cybersec.internal/ \
    https://www.cybersec.internal/ \
    https://services.cybersec.internal/
do
    CODE=$(curl --noproxy '*' --silent --show-error --output /dev/null --write-out '%{http_code}' "$URL")
    printf '%-46s HTTP %s\n' "$URL" "$CODE"
    [ "$CODE" = '200' ]
done
'@
            Invoke-NodeScript -Node "red" -Name "final-browser-vm-verification" -Content $VerifyRedScript -CaptureOutputPath $FinalVerificationPath
        }
        catch {
            Write-Warning "De optionele eindtest op red faalde: $($_.Exception.Message)"
            Add-Utf8NoBomText -Path $FinalVerificationPath -Content ("`n### red/browser-vm`nOptionele test faalde: " + $_.Exception.Message + "`n")
        }
    }

    $VerifyExternalScript = @'
#!/bin/sh
set -eu

sudo apk add --no-cache curl >/dev/null
CA=/etc/csa-ca/certs/ca.crt
SERVER=172.30.0.10

echo '=== ISPROUTER: HTTPS THROUGH COMPANYROUTER FIREWALL ==='
for HOST in cybersec.internal www.cybersec.internal services.cybersec.internal; do
    CODE=$(curl --noproxy '*' \
        --resolve "$HOST:443:$SERVER" \
        --cacert "$CA" \
        --tlsv1.3 --tls-max 1.3 \
        --silent --show-error --output /dev/null --write-out '%{http_code}' \
        "https://$HOST/")
    printf '%-42s HTTP %s\n' "https://$HOST/" "$CODE"
    [ "$CODE" = '200' ]
done
'@
    Invoke-NodeScript -Node "isprouter" -Name "final-external-https-verification" -Content $VerifyExternalScript -CaptureOutputPath $FinalVerificationPath

    $VerifyFirewallScript = @'
#!/bin/sh
set -eu

echo '=== COMPANYROUTER: ACTIVE FORWARD RULES ==='
sudo nft -n list chain inet csa_firewall forward
sudo nft -n list chain inet csa_firewall forward | grep -E '172\.30\.0\.4.*dport 53'
sudo nft -n list chain inet csa_firewall forward | grep -E '172\.30\.0\.10.*dport.*(80|443)'

echo
echo '=== COMPANYROUTER: PERSISTENCE SERVICE ==='
systemctl is-enabled csa-firewall.service
systemctl is-active csa-firewall.service
'@
    Invoke-NodeScript -Node "companyrouter" -Name "final-firewall-verification" -Content $VerifyFirewallScript -CaptureOutputPath $FinalVerificationPath

    Add-Utf8NoBomText -Path $FinalVerificationPath -Content "`n### Git diff --check`n"
    $GitDiffCheck = & git -c core.safecrlf=false diff --check 2>&1
    $GitDiffExitCode = $LASTEXITCODE
    $GitDiffCheck | ForEach-Object { Write-Output $_ }
    Add-Utf8NoBomText -Path $FinalVerificationPath -Content ((($GitDiffCheck | Out-String).TrimEnd()) + "`n")
    if ($GitDiffExitCode -ne 0) {
        throw "git diff --check meldt whitespacefouten."
    }

    $GitStatus = & git status --short 2>&1
    Write-Output $GitStatus
    Add-Utf8NoBomText -Path $FinalVerificationPath -Content ("`n### Git status --short`n" + (($GitStatus | Out-String).TrimEnd()) + "`n")

    Write-Host ""
    Write-Host "LAB 6 COMPLETE" -ForegroundColor Green
    Write-Host "Eindtoestand: uitsluitend TLS 1.3 op poort 443." -ForegroundColor Green
    Write-Host "Evidence: $Evidence" -ForegroundColor Cyan
    Write-Host "Private Wireshark-files: $PrivateDirectory" -ForegroundColor Magenta
    Write-Host ""
    Write-Host "Na controle kun je uitsluitend Lab 6 stage-en met:" -ForegroundColor Yellow
    Write-Host @"
git add -- .gitignore `
  ansible/webserver.yml `
  ansible/files/dns/etc/cybersec.internal `
  ansible/files/web/etc/httpd.conf `
  ansible/files/web/etc/lab6-https-tls12.conf `
  ansible/files/web/etc/lab6-https-tls13.conf `
  configs/firewall/companyrouter.nft `
  configs/pki/webserver.cnf `
  scripts/lab6-https.ps1 `
  evidence/06-https

git commit -m "feat: complete lab 6 CA and HTTPS"
"@

    $Succeeded = $true
}
finally {
    if ($TranscriptStarted) {
        Stop-Transcript | Out-Null
    }

    if ($Succeeded) {
        Remove-Item -LiteralPath $WorkDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    else {
        Write-Warning "Lab 6 stopte vóór volledige afronding. Tijdelijke debugbestanden staan in: $WorkDir"
        Write-Warning "Bekijk ook: $BuildLogPath"
    }
}
