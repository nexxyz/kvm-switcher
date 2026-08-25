[CmdletBinding()]
param(
    [switch]$MonitorAwake
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2.0

function Fail-LiveFat {
    param([string]$Message)
    throw $Message
}

function Assert-File {
    param([string]$Path, [string]$Label)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Fail-LiveFat ("Missing " + $Label)
    }
}

function Get-ConfigState {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [pscustomobject]@{
            Exists = $false
            Hash = ""
            LastWriteUtc = 0L
            Length = 0L
        }
    }

    $item = Get-Item -LiteralPath $Path
    return [pscustomobject]@{
        Exists = $true
        Hash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
        LastWriteUtc = $item.LastWriteTimeUtc.Ticks
        Length = $item.Length
    }
}

function Assert-ExactZip {
    param([string]$Path)

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $expectedEntries = @(
        "KvmSwitcher.exe",
        "KvmSwitcher.dll",
        "KvmSwitcher.deps.json",
        "KvmSwitcher.runtimeconfig.json",
        "HidSharp.dll",
        "kvm-switcher_0.8.2-1_all.deb",
        "LICENSE",
        "THIRD-PARTY-NOTICES.txt"
    )

    $archive = [System.IO.Compression.ZipFile]::OpenRead($Path)
    try {
        $entries = @($archive.Entries)
        if ($entries.Count -ne $expectedEntries.Count) {
            Fail-LiveFat "Windows artifact ZIP does not contain exactly eight entries"
        }
        foreach ($entry in $entries) {
            if ($entry.FullName.EndsWith("/") -or $expectedEntries -notcontains $entry.FullName) {
                Fail-LiveFat "Windows artifact ZIP contains an unexpected entry"
            }
            if ($entry.Length -le 0) {
                Fail-LiveFat "Windows artifact ZIP contains an empty entry"
            }
        }
    }
    finally {
        $archive.Dispose()
    }
}

function Assert-ExactOnlineBundle {
    param([string]$Path)

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $expectedEntries = @("kvm-switcher_0.8.2-1_all.deb", "config.json", "install.sh", "README.md", "LICENSE", "SHA256SUMS")
    $archive = [System.IO.Compression.ZipFile]::OpenRead($Path)
    try {
        $entries = @($archive.Entries)
        if ($entries.Count -ne $expectedEntries.Count) {
            Fail-LiveFat "Debian online fallback bundle does not contain exactly six entries"
        }
        foreach ($entry in $entries) {
            if ($entry.FullName.EndsWith("/") -or $expectedEntries -notcontains $entry.FullName -or $entry.Length -le 0) {
                Fail-LiveFat "Debian online fallback bundle contains an invalid entry"
            }
        }
    }
    finally {
        $archive.Dispose()
    }
}

if (-not $MonitorAwake) {
    Write-Host "FAIL: pass -MonitorAwake only when the User is present and the monitor is awake" -ForegroundColor Red
    exit 2
}

$scriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = (Resolve-Path (Join-Path $scriptDirectory "..")).Path
$artifactRoot = Join-Path $repoRoot "artifacts"
$zipPath = Join-Path $artifactRoot "KvmSwitcher-win-x64.zip"
$setupPath = Join-Path $artifactRoot "KvmSwitcher-Setup.exe"
$sumsPath = Join-Path $artifactRoot "SHA256SUMS.txt"
$onlineInstallerPath = Join-Path $artifactRoot "install-kvm-switcher.sh"
$debianBundlePath = Join-Path $artifactRoot "kvm-switcher-debian.zip"
$tempRoot = $null
$probeProcess = $null
$success = $false
$failureMessage = ""

try {
    Assert-File -Path $zipPath -Label "Windows artifact ZIP"
    Assert-File -Path $setupPath -Label "Windows setup artifact"
    Assert-File -Path $onlineInstallerPath -Label "online Debian bootstrap installer"
    Assert-File -Path $debianBundlePath -Label "online Debian fallback bundle"
    Assert-File -Path $sumsPath -Label "Windows artifact SHA256SUMS.txt"

    $expectedNames = @("KvmSwitcher-Setup.exe", "KvmSwitcher-win-x64.zip", "install-kvm-switcher.sh", "kvm-switcher-debian.zip")
    $sumLines = @(Get-Content -LiteralPath $sumsPath | Where-Object { $_.Trim().Length -ne 0 })
    if ($sumLines.Count -ne 4) {
        Fail-LiveFat "SHA256SUMS.txt must contain exactly four release asset hashes"
    }
    $manifest = @{}
    foreach ($sumLine in $sumLines) {
        $sumParts = $sumLine.Trim() -split "\s+"
        if ($sumParts.Count -ne 2 -or $sumParts[0] -notmatch '^[0-9a-f]{64}$' -or $expectedNames -notcontains $sumParts[1]) {
            Fail-LiveFat "SHA256SUMS.txt contains an invalid entry"
        }
        if ($manifest.ContainsKey($sumParts[1])) {
            Fail-LiveFat "SHA256SUMS.txt contains a duplicate entry"
        }
        $manifest[$sumParts[1]] = $sumParts[0].ToLowerInvariant()
    }
    foreach ($expectedName in $expectedNames) {
        if (-not $manifest.ContainsKey($expectedName)) {
            Fail-LiveFat "SHA256SUMS.txt is missing an expected entry"
        }
    }
    $actualHash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualHash -ne $manifest["KvmSwitcher-win-x64.zip"]) {
        Fail-LiveFat "Windows artifact hash mismatch"
    }
    $actualSetupHash = (Get-FileHash -LiteralPath $setupPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualSetupHash -ne $manifest["KvmSwitcher-Setup.exe"]) {
        Fail-LiveFat "Windows setup artifact hash mismatch"
    }
    $actualOnlineInstallerHash = (Get-FileHash -LiteralPath $onlineInstallerPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualOnlineInstallerHash -ne $manifest["install-kvm-switcher.sh"]) {
        Fail-LiveFat "online Debian bootstrap installer hash mismatch"
    }
    $actualDebianBundleHash = (Get-FileHash -LiteralPath $debianBundlePath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualDebianBundleHash -ne $manifest["kvm-switcher-debian.zip"]) {
        Fail-LiveFat "online Debian fallback bundle hash mismatch"
    }
    Assert-ExactZip -Path $zipPath
    Assert-ExactOnlineBundle -Path $debianBundlePath

    foreach ($processName in @("KvmSwitcher", "GamingIntelligence", "MonitorMicroKeyDetector")) {
        $running = @(Get-Process -Name $processName -ErrorAction SilentlyContinue)
        if ($running.Count -ne 0) {
            Fail-LiveFat ("Process must be stopped before live FAT: " + $processName)
        }
    }

    $pnpCommand = Get-Command Get-PnpDevice -ErrorAction SilentlyContinue
    if ($null -eq $pnpCommand) {
        Fail-LiveFat "Get-PnpDevice is required for sanitized live context"
    }
    try {
        $pnpRecords = @(Get-PnpDevice -PresentOnly -ErrorAction Stop | Where-Object {
            $_.InstanceId -match "^(?i:HID|USB)\\VID_1462&PID_3FA4\\"
        })
    }
    catch {
        Fail-LiveFat "Get-PnpDevice could not collect the sanitized VID/PID context"
    }

    $statusCounts = @{}
    foreach ($record in $pnpRecords) {
        $status = [string]$record.Status
        if (-not $statusCounts.ContainsKey($status)) {
            $statusCounts[$status] = 0
        }
        $statusCounts[$status]++
    }
    $statusSummary = @($statusCounts.GetEnumerator() | Sort-Object Name | ForEach-Object {
        $_.Name + "=" + $_.Value
    }) -join ", "
    $healthyCount = @($pnpRecords | Where-Object { $_.Status -eq "OK" }).Count

    $localAppData = $env:LOCALAPPDATA
    if ([string]::IsNullOrWhiteSpace($localAppData)) {
        Fail-LiveFat "LOCALAPPDATA is unavailable"
    }
    $configPath = Join-Path $localAppData "KvmSwitcher\config.json"
    $configBefore = Get-ConfigState -Path $configPath

    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("KvmSwitcher-LiveHardwareFat-" + [Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    [System.IO.Compression.ZipFile]::ExtractToDirectory($zipPath, $tempRoot)
    $probePath = Join-Path $tempRoot "KvmSwitcher.exe"
    Assert-File -Path $probePath -Label "extracted KvmSwitcher.exe"

    $probeProcess = Start-Process -FilePath $probePath -ArgumentList @("--probe-hardware") -PassThru -WindowStyle Hidden
    if (-not $probeProcess.WaitForExit(15000)) {
        try { $probeProcess.Kill() } catch { }
        Fail-LiveFat "hardware probe exceeded the 15 second bound"
    }
    if (-not $probeProcess.HasExited) {
        Fail-LiveFat "hardware probe process did not exit"
    }
    $probeExitCode = $probeProcess.ExitCode
    if ($probeExitCode -ne 0) {
        Fail-LiveFat ("hardware probe returned exit code " + $probeExitCode)
    }

    $configAfter = Get-ConfigState -Path $configPath
    if ($configBefore.Exists -ne $configAfter.Exists) {
        Fail-LiveFat "probe changed the KvmSwitcher configuration file presence"
    }
    if ($configBefore.Exists -and
        ($configBefore.Hash -ne $configAfter.Hash -or
         $configBefore.LastWriteUtc -ne $configAfter.LastWriteUtc -or
         $configBefore.Length -ne $configAfter.Length)) {
        Fail-LiveFat "probe changed the KvmSwitcher configuration file"
    }

    $utc = [DateTime]::UtcNow.ToString("o", [Globalization.CultureInfo]::InvariantCulture)
    Write-Host "PASS: passive live-hardware FAT" -ForegroundColor Green
    Write-Host ("  UTC: " + $utc)
    Write-Host ("  OS version: " + [Environment]::OSVersion.Version.ToString())
    Write-Host ("  ZIP SHA256: " + $actualHash)
    Write-Host ("  Setup SHA256: " + $actualSetupHash)
    Write-Host ("  Online installer SHA256: " + $actualOnlineInstallerHash)
    Write-Host ("  Debian fallback bundle SHA256: " + $actualDebianBundleHash)
    Write-Host ("  Healthy PnP VID/PID records: " + $healthyCount + "/" + $pnpRecords.Count + "; statuses: " + $statusSummary)
    Write-Host "  Probe: success (exit code 0; discovery/open/close completed; no report I/O)"
    $success = $true
}
catch {
    $failureMessage = [string]$_.Exception.Message
}
finally {
    if ($null -ne $tempRoot -and (Test-Path -LiteralPath $tempRoot)) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if (-not $success) {
    Write-Host ("FAIL: passive live-hardware FAT - " + $failureMessage) -ForegroundColor Red
    exit 1
}
