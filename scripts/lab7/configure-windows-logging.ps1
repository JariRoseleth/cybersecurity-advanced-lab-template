$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$WorkDir = 'C:\CSA-Lab7'
$SysmonZip = Join-Path $WorkDir 'Sysmon.zip'
$SysmonDir = Join-Path $WorkDir 'Sysmon'
$SysmonConfig = Join-Path $WorkDir 'sysmonconfig.xml'
$OssecConfig = 'C:\Program Files (x86)\ossec-agent\ossec.conf'
$OssecLog = 'C:\Program Files (x86)\ossec-agent\ossec.log'

New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null

Write-Host "`n=== RUNNING INSIDE WINDOWS VM ===" -ForegroundColor Cyan
Write-Host "Computer: $env:COMPUTERNAME"
Write-Host "User: $env:USERNAME"

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
$IsAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
Write-Host "Elevated: $IsAdmin"

if (-not $IsAdmin) {
    throw 'WinRM process is not elevated.'
}

Write-Host "`n=== 1. WAZUH AGENT ===" -ForegroundColor Cyan
$Wazuh = Get-Service -Name 'WazuhSvc' -ErrorAction Stop
$Wazuh | Format-Table Name, Status, StartType -AutoSize
if ($Wazuh.Status -ne 'Running') {
    Start-Service WazuhSvc
    Start-Sleep -Seconds 3
}

if (-not (Test-Path -LiteralPath $OssecConfig)) {
    throw "Wazuh ossec.conf not found at $OssecConfig"
}

Write-Host "`n=== 2. DOWNLOAD SYSMON ===" -ForegroundColor Cyan
Invoke-WebRequest -UseBasicParsing -Uri 'https://download.sysinternals.com/files/Sysmon.zip' -OutFile $SysmonZip
Remove-Item -LiteralPath $SysmonDir -Recurse -Force -ErrorAction SilentlyContinue
Expand-Archive -LiteralPath $SysmonZip -DestinationPath $SysmonDir -Force
$SysmonExe = Join-Path $SysmonDir 'Sysmon64.exe'
if (-not (Test-Path -LiteralPath $SysmonExe)) {
    throw 'Sysmon64.exe was not found after extraction.'
}

Write-Host "`n=== 3. CREATE SYSMON CONFIG ===" -ForegroundColor Cyan
$ConfigLines = @(
    '<Sysmon schemaversion="4.90">',
    '  <HashAlgorithms>SHA256</HashAlgorithms>',
    '  <EventFiltering>',
    '    <ProcessCreate onmatch="exclude" />',
    '  </EventFiltering>',
    '</Sysmon>'
)
[System.IO.File]::WriteAllLines($SysmonConfig, $ConfigLines, [System.Text.UTF8Encoding]::new($false))
Get-Content -LiteralPath $SysmonConfig

Write-Host "`n=== 4. INSTALL OR UPDATE SYSMON ===" -ForegroundColor Cyan
$ExistingSysmon = @(Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'Sysmon*' })
if ($ExistingSysmon.Count -eq 0) {
    & $SysmonExe -accepteula -i $SysmonConfig
    if ($LASTEXITCODE -ne 0) { throw "Sysmon install failed with exit code $LASTEXITCODE" }
} else {
    & $SysmonExe -accepteula -c $SysmonConfig
    if ($LASTEXITCODE -ne 0) { throw "Sysmon config update failed with exit code $LASTEXITCODE" }
}

Write-Host "`n=== 5. ENABLE POWERSHELL LOGGING ===" -ForegroundColor Cyan
$SB = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ScriptBlockLogging'
$ML = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ModuleLogging'
$MN = Join-Path $ML 'ModuleNames'
New-Item -Path $SB -Force | Out-Null
New-ItemProperty -Path $SB -Name 'EnableScriptBlockLogging' -PropertyType DWord -Value 1 -Force | Out-Null
New-Item -Path $ML -Force | Out-Null
New-ItemProperty -Path $ML -Name 'EnableModuleLogging' -PropertyType DWord -Value 1 -Force | Out-Null
New-Item -Path $MN -Force | Out-Null
New-ItemProperty -Path $MN -Name '*' -PropertyType String -Value '*' -Force | Out-Null
& wevtutil.exe sl 'Microsoft-Windows-PowerShell/Operational' /e:true
if ($LASTEXITCODE -ne 0) { throw 'Could not enable PowerShell Operational log.' }

Write-Host "`n=== 6. CONFIGURE WAZUH EVENTCHANNELS ===" -ForegroundColor Cyan
$Text = [System.IO.File]::ReadAllText($OssecConfig)
$AppendBlocks = New-Object System.Collections.Generic.List[string]

if ($Text -notmatch [regex]::Escape('Microsoft-Windows-Sysmon/Operational')) {
    $AppendBlocks.Add([string]::Join("`r`n", @(
        '<ossec_config>',
        '  <localfile>',
        '    <location>Microsoft-Windows-Sysmon/Operational</location>',
        '    <log_format>eventchannel</log_format>',
        '  </localfile>',
        '</ossec_config>'
    )))
}

if ($Text -notmatch [regex]::Escape('Microsoft-Windows-PowerShell/Operational')) {
    $AppendBlocks.Add([string]::Join("`r`n", @(
        '<ossec_config>',
        '  <localfile>',
        '    <location>Microsoft-Windows-PowerShell/Operational</location>',
        '    <log_format>eventchannel</log_format>',
        '  </localfile>',
        '</ossec_config>'
    )))
}

if ($AppendBlocks.Count -gt 0) {
    Copy-Item -LiteralPath $OssecConfig -Destination "$OssecConfig.before-lab7" -Force
    $Text = $Text.TrimEnd() + "`r`n`r`n" + [string]::Join("`r`n`r`n", $AppendBlocks) + "`r`n"
    [System.IO.File]::WriteAllText($OssecConfig, $Text, [System.Text.UTF8Encoding]::new($false))
}

Select-String -LiteralPath $OssecConfig -Pattern 'Microsoft-Windows-Sysmon/Operational','Microsoft-Windows-PowerShell/Operational' -Context 1,2

Write-Host "`n=== 7. RESTART WAZUH AGENT ===" -ForegroundColor Cyan
Restart-Service WazuhSvc
Start-Sleep -Seconds 8
$Wazuh = Get-Service WazuhSvc
if ($Wazuh.Status -ne 'Running') { throw 'WazuhSvc did not return to Running.' }

Write-Host "`n=== 8. SERVICES AND LOG CHANNELS ===" -ForegroundColor Cyan
Get-Service | Where-Object { $_.Name -eq 'WazuhSvc' -or $_.Name -like 'Sysmon*' } | Format-Table Name, Status, StartType -AutoSize
$SysmonLog = Get-WinEvent -ListLog 'Microsoft-Windows-Sysmon/Operational'
$PsLog = Get-WinEvent -ListLog 'Microsoft-Windows-PowerShell/Operational'
$SysmonLog | Select-Object LogName, IsEnabled, RecordCount | Format-List
$PsLog | Select-Object LogName, IsEnabled, RecordCount | Format-List

Write-Host "`n=== 9. GENERATE TEST EVENTS ===" -ForegroundColor Cyan
$StartTime = (Get-Date).AddSeconds(-2)
& cmd.exe /d /c 'echo LAB7_CMD_PROCESS_MARKER && whoami && hostname'
& powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Write-Output 'LAB7_POWERSHELL_4104_MARKER'; Get-Date; Get-Service WazuhSvc | Select-Object Name,Status"
Start-Sleep -Seconds 10

Write-Host "`n=== 10. LOCAL SYSMON EVENT ID 1 ===" -ForegroundColor Cyan
$SysmonEvents = @(Get-WinEvent -FilterHashtable @{ LogName='Microsoft-Windows-Sysmon/Operational'; Id=1; StartTime=$StartTime } -ErrorAction Stop | Where-Object { $_.Message -match 'LAB7_CMD_PROCESS_MARKER' })
if ($SysmonEvents.Count -eq 0) {
    $Recent = @(Get-WinEvent -FilterHashtable @{ LogName='Microsoft-Windows-Sysmon/Operational'; Id=1 } -MaxEvents 20 -ErrorAction SilentlyContinue)
    Write-Host 'Recent Sysmon process events:'
    $Recent | Select-Object TimeCreated, Id, Message | Format-List
    throw 'No Sysmon Event ID 1 containing LAB7_CMD_PROCESS_MARKER was found.'
}
$SysmonEvents | Select-Object TimeCreated, Id, @{N='Message';E={(($_.Message -replace "`r|`n",' ') -replace '\s+',' ')}} | Format-List

Write-Host "`n=== 11. LOCAL POWERSHELL EVENT 4104 ===" -ForegroundColor Cyan
$PsEvents = @(Get-WinEvent -FilterHashtable @{ LogName='Microsoft-Windows-PowerShell/Operational'; Id=4104; StartTime=$StartTime } -ErrorAction Stop | Where-Object { $_.Message -match 'LAB7_POWERSHELL_4104_MARKER' })
if ($PsEvents.Count -eq 0) { throw 'No PowerShell 4104 marker event was found.' }
$PsEvents | Select-Object TimeCreated, Id, @{N='Message';E={(($_.Message -replace "`r|`n",' ') -replace '\s+',' ')}} | Format-List

Write-Host "`n=== 12. WAZUH LOGCOLLECTOR ===" -ForegroundColor Cyan
if (Test-Path -LiteralPath $OssecLog) {
    Get-Content -LiteralPath $OssecLog -Tail 200 | Select-String -Pattern 'Sysmon|PowerShell|eventchannel|connected|Analyzing event log' -CaseSensitive:$false
}

$HealthFile = Join-Path $WorkDir 'windows-logging-health.txt'
$HealthLines = @(
    '==================================================',
    'CSA LAB 7 - WINDOWS LOGGING HEALTH',
    '==================================================',
    "Generated: $((Get-Date).ToString('o'))",
    "Computer: $env:COMPUTERNAME",
    "WazuhSvc: $((Get-Service WazuhSvc).Status)",
    "SysmonService: $((Get-Service | Where-Object { $_.Name -like 'Sysmon*' } | Select-Object -First 1 -ExpandProperty Status))",
    "SysmonChannelEnabled: $($SysmonLog.IsEnabled)",
    "PowerShellChannelEnabled: $($PsLog.IsEnabled)",
    "SysmonMarkerEvents: $($SysmonEvents.Count)",
    "PowerShell4104MarkerEvents: $($PsEvents.Count)"
)
[System.IO.File]::WriteAllLines($HealthFile, $HealthLines, [System.Text.UTF8Encoding]::new($false))
Get-Content -LiteralPath $HealthFile

Write-Host "`n============================================" -ForegroundColor Green
Write-Host 'SYSMON_AND_POWERSHELL_LOGGING_READY' -ForegroundColor Green
Write-Host '============================================' -ForegroundColor Green
