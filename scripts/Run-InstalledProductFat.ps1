[CmdletBinding()]
param(
    [switch]$AllowInstall,
    [switch]$MonitorAwake
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2.0

function Fail-InstalledFat {
    param([string]$Message)
    throw $Message
}

function Assert-File {
    param([string]$Path, [string]$Label)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Fail-InstalledFat ("Missing " + $Label)
    }
}

function Get-ConfigState {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [pscustomobject]@{ Exists = $false; Hash = ""; Length = 0L; LastWriteUtc = 0L }
    }
    $item = Get-Item -LiteralPath $Path
    return [pscustomobject]@{
        Exists = $true
        Hash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
        Length = $item.Length
        LastWriteUtc = $item.LastWriteTimeUtc.Ticks
    }
}

function Assert-ConfigUnchanged {
    param([object]$Before, [object]$After)
    if ($Before.Exists -ne $After.Exists) {
        Fail-InstalledFat "Installed product changed KvmSwitcher config presence"
    }
    if ($Before.Exists -and
        ($Before.Hash -ne $After.Hash -or
         $Before.Length -ne $After.Length -or
         $Before.LastWriteUtc -ne $After.LastWriteUtc)) {
        Fail-InstalledFat "Installed product changed KvmSwitcher config"
    }
}

function Read-Manifest {
    param([string]$Path)
    $expectedNames = @("KvmSwitcher-Setup.exe", "KvmSwitcher-win-x64.zip", "install-kvm-switcher.sh", "kvm-switcher-debian.zip")
    $lines = @(Get-Content -LiteralPath $Path | Where-Object { $_.Trim().Length -ne 0 })
    if ($lines.Count -ne 4) {
        Fail-InstalledFat "SHA256SUMS.txt must contain exactly four release asset entries"
    }

    $manifest = @{}
    foreach ($line in $lines) {
        $parts = $line.Trim() -split "\s+"
        if ($parts.Count -ne 2 -or $parts[0] -notmatch '^[0-9a-f]{64}$' -or $expectedNames -notcontains $parts[1]) {
            Fail-InstalledFat "SHA256SUMS.txt contains an invalid entry"
        }
        if ($manifest.ContainsKey($parts[1])) {
            Fail-InstalledFat "SHA256SUMS.txt contains a duplicate entry"
        }
        $manifest[$parts[1]] = $parts[0].ToLowerInvariant()
    }
    foreach ($name in $expectedNames) {
        if (-not $manifest.ContainsKey($name)) {
            Fail-InstalledFat "SHA256SUMS.txt is missing an expected entry"
        }
    }
    return $manifest
}

function Assert-ExactZip {
    param([string]$Path)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $expected = @("KvmSwitcher.exe", "KvmSwitcher.dll", "KvmSwitcher.deps.json", "KvmSwitcher.runtimeconfig.json", "HidSharp.dll", "kvm-switcher_0.8.0-1_all.deb", "LICENSE", "THIRD-PARTY-NOTICES.txt")
    $archive = [System.IO.Compression.ZipFile]::OpenRead($Path)
    try {
        $entries = @($archive.Entries)
        if ($entries.Count -ne $expected.Count) {
            Fail-InstalledFat "Windows ZIP does not contain exactly eight entries"
        }
        foreach ($entry in $entries) {
            if ($entry.FullName.EndsWith("/") -or $expected -notcontains $entry.FullName -or $entry.Length -le 0) {
                Fail-InstalledFat "Windows ZIP contains an invalid entry"
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
    $expected = @("kvm-switcher_0.8.0-1_all.deb", "config.json", "install.sh", "README.md", "LICENSE", "SHA256SUMS")
    $archive = [System.IO.Compression.ZipFile]::OpenRead($Path)
    try {
        $entries = @($archive.Entries)
        if ($entries.Count -ne $expected.Count) {
            Fail-InstalledFat "Debian online fallback bundle does not contain exactly six entries"
        }
        foreach ($entry in $entries) {
            if ($entry.FullName.EndsWith("/") -or $expected -notcontains $entry.FullName -or $entry.Length -le 0) {
                Fail-InstalledFat "Debian online fallback bundle contains an invalid entry"
            }
        }
    }
    finally {
        $archive.Dispose()
    }
}

function Invoke-BoundedProcess {
    param([string]$FilePath, [string[]]$Arguments, [int]$TimeoutMilliseconds, [string]$Label)
    $process = Start-Process -FilePath $FilePath -ArgumentList $Arguments -PassThru -WindowStyle Hidden
    if (-not $process.WaitForExit($TimeoutMilliseconds)) {
        Fail-InstalledFat ($Label + " exceeded its bounded timeout")
    }
    if (-not $process.HasExited) {
        Fail-InstalledFat ($Label + " did not exit")
    }
    return $process.ExitCode
}

function Wait-ForPathRemoval {
    param([string]$Path, [int]$TimeoutMilliseconds)
    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMilliseconds)
    while ((Test-Path -LiteralPath $Path) -and [DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 100
    }
}

function Assert-NoProductProcesses {
    foreach ($name in @("KvmSwitcher", "GamingIntelligence", "MonitorMicroKeyDetector")) {
        if (@(Get-Process -Name $name -ErrorAction SilentlyContinue).Count -ne 0) {
            Fail-InstalledFat ("Process must be stopped before installed FAT: " + $name)
        }
    }
}

function Assert-MutexAbsent {
    $mutex = $null
    try {
        $mutex = [System.Threading.Mutex]::OpenExisting("Local\KvmSwitcher.SingleInstance")
        if ($null -ne $mutex) {
            Fail-InstalledFat "KvmSwitcher product mutex already exists"
        }
    }
    catch [System.Threading.WaitHandleCannotBeOpenedException] {
    }
    catch {
        Fail-InstalledFat "Could not safely inspect the KvmSwitcher product mutex"
    }
    finally {
        if ($null -ne $mutex) {
            $mutex.Dispose()
        }
    }
}

function Get-UninstallKeyPaths {
    param([string]$AppId)
    $base = "Software\Microsoft\Windows\CurrentVersion\Uninstall\" + $AppId + "_is1"
    $wowBase = "Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\" + $AppId + "_is1"
    return @("HKCU:\$base", "HKCU:\$wowBase")
}

function Get-UninstallEntry {
    param([string[]]$KeyPaths)
    foreach ($keyPath in $KeyPaths) {
        if (Test-Path -LiteralPath $keyPath) {
            return [pscustomobject]@{ Path = $keyPath; Properties = Get-ItemProperty -LiteralPath $keyPath }
        }
    }
    return $null
}

function Assert-NoUninstallEntry {
    param([string[]]$KeyPaths)
    if ($null -ne (Get-UninstallEntry -KeyPaths $KeyPaths)) {
        Fail-InstalledFat "KvmSwitcher AppId uninstall entry already exists"
    }
}

function Get-StartupValue {
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey("Software\Microsoft\Windows\CurrentVersion\Run", $false)
    if ($null -eq $key) {
        return [pscustomobject]@{ Present = $false; Value = "" }
    }
    try {
        $names = @($key.GetValueNames())
        if ($names -contains "KvmSwitcher") {
            return [pscustomobject]@{ Present = $true; Value = [string]$key.GetValue("KvmSwitcher", "", [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) }
        }
        return [pscustomobject]@{ Present = $false; Value = "" }
    }
    finally {
        $key.Dispose()
    }
}

function Assert-NoShortcut {
    $programs = [Environment]::GetFolderPath([Environment+SpecialFolder]::Programs)
    $shortcut = Join-Path $programs "KVM Switcher.lnk"
    if (Test-Path -LiteralPath $shortcut) {
        Fail-InstalledFat "KVM Switcher Start Menu shortcut already exists"
    }
}

function Assert-InstalledPayload {
    param([string]$InstallDirectory, [string]$PayloadDirectory)
    $names = @("KvmSwitcher.exe", "KvmSwitcher.dll", "KvmSwitcher.deps.json", "KvmSwitcher.runtimeconfig.json", "HidSharp.dll", "kvm-switcher_0.8.0-1_all.deb", "LICENSE", "THIRD-PARTY-NOTICES.txt")
    foreach ($name in $names) {
        $installed = Join-Path $InstallDirectory $name
        $expected = Join-Path $PayloadDirectory $name
        Assert-File -Path $installed -Label ("installed " + $name)
        if ((Get-FileHash -LiteralPath $installed -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath $expected -Algorithm SHA256).Hash) {
            Fail-InstalledFat ("Installed payload hash mismatch for " + $name)
        }
    }
    Assert-File -Path (Join-Path $InstallDirectory "unins000.exe") -Label "installed uninstaller"
}

function Assert-InstalledMetadata {
    param([string[]]$UninstallKeyPaths, [string]$ExpectedVersion)
    $entry = Get-UninstallEntry -KeyPaths $UninstallKeyPaths
    if ($null -eq $entry) {
        Fail-InstalledFat "KvmSwitcher AppId uninstall entry is missing"
    }
    if ([string]$entry.Properties.DisplayName -ne "KVM Switcher" -or [string]$entry.Properties.DisplayVersion -ne $ExpectedVersion) {
        Fail-InstalledFat "KvmSwitcher uninstall metadata is incorrect"
    }
}

if (-not $AllowInstall -or -not $MonitorAwake) {
    Write-Host "FAIL: pass both -AllowInstall and -MonitorAwake only for the attended installed FAT" -ForegroundColor Red
    exit 2
}

$scriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = (Resolve-Path (Join-Path $scriptDirectory "..")).Path
$artifactRoot = Join-Path $repoRoot "artifacts"
$zipPath = Join-Path $artifactRoot "KvmSwitcher-win-x64.zip"
$setupPath = Join-Path $artifactRoot "KvmSwitcher-Setup.exe"
$onlineInstallerPath = Join-Path $artifactRoot "install-kvm-switcher.sh"
$debianBundlePath = Join-Path $artifactRoot "kvm-switcher-debian.zip"
$manifestPath = Join-Path $artifactRoot "SHA256SUMS.txt"
$tempRoot = $null
$success = $false
$failureMessage = ""
$appId = "{12CCB92F-EF08-43B1-A44F-96CDAB17D949}"
$uninstallKeyPaths = Get-UninstallKeyPaths -AppId $appId
if ($uninstallKeyPaths.Count -ne 2) {
    Write-Host "FAIL: installed-product FAT constructed invalid uninstall registry paths" -ForegroundColor Red
    exit 1
}
$installDirectory = $null
$configPath = $null
$startMenuShortcut = $null

try {
    if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        Fail-InstalledFat "LOCALAPPDATA is unavailable"
    }
    $installDirectory = Join-Path $env:LOCALAPPDATA "Programs\KvmSwitcher"
    $configPath = Join-Path $env:LOCALAPPDATA "KvmSwitcher\config.json"
    $startMenuPrograms = [Environment]::GetFolderPath([Environment+SpecialFolder]::Programs)
    $startMenuShortcut = Join-Path $startMenuPrograms "KVM Switcher.lnk"
    Assert-File -Path $zipPath -Label "Windows ZIP"
    Assert-File -Path $setupPath -Label "KVM Switcher installer"
    Assert-File -Path $onlineInstallerPath -Label "online Debian bootstrap installer"
    Assert-File -Path $debianBundlePath -Label "online Debian fallback bundle"
    Assert-File -Path $manifestPath -Label "SHA256SUMS.txt"
    $manifest = Read-Manifest -Path $manifestPath
    Assert-ExactZip -Path $zipPath
    Assert-ExactOnlineBundle -Path $debianBundlePath
    if ((Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant() -ne $manifest["KvmSwitcher-win-x64.zip"]) {
        Fail-InstalledFat "Windows ZIP hash does not match SHA256SUMS.txt"
    }
    if ((Get-FileHash -LiteralPath $setupPath -Algorithm SHA256).Hash.ToLowerInvariant() -ne $manifest["KvmSwitcher-Setup.exe"]) {
        Fail-InstalledFat "Installer hash does not match SHA256SUMS.txt"
    }
    if ((Get-FileHash -LiteralPath $onlineInstallerPath -Algorithm SHA256).Hash.ToLowerInvariant() -ne $manifest["install-kvm-switcher.sh"]) {
        Fail-InstalledFat "online Debian bootstrap installer hash does not match SHA256SUMS.txt"
    }
    if ((Get-FileHash -LiteralPath $debianBundlePath -Algorithm SHA256).Hash.ToLowerInvariant() -ne $manifest["kvm-switcher-debian.zip"]) {
        Fail-InstalledFat "online Debian fallback bundle hash does not match SHA256SUMS.txt"
    }

    Assert-NoProductProcesses
    Assert-MutexAbsent
    if (Test-Path -LiteralPath $installDirectory) {
        Fail-InstalledFat "Default KvmSwitcher install directory already exists"
    }
    Assert-NoUninstallEntry -KeyPaths $uninstallKeyPaths
    Assert-NoShortcut
    if ((Get-StartupValue).Present) {
        Fail-InstalledFat "KvmSwitcher startup value already exists"
    }

    $configBefore = Get-ConfigState -Path $configPath
    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("KvmSwitcher-InstalledFat-" + [Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    [System.IO.Compression.ZipFile]::ExtractToDirectory($zipPath, $tempRoot)
    $zipExePath = Join-Path $tempRoot "KvmSwitcher.exe"
    Assert-File -Path $zipExePath -Label "ZIP KvmSwitcher.exe"
    $expectedVersion = [Diagnostics.FileVersionInfo]::GetVersionInfo($zipExePath).FileVersion
    if ($expectedVersion -notmatch '^\d+\.\d+\.\d+\.\d+$') {
        Fail-InstalledFat "ZIP KvmSwitcher.exe has no numeric four-part file version"
    }

    $installExit = Invoke-BoundedProcess -FilePath $setupPath -Arguments @("/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART", "/SP-") -TimeoutMilliseconds 120000 -Label "initial installer"
    if ($installExit -ne 0) {
        Fail-InstalledFat ("initial installer returned exit code " + $installExit)
    }
    Assert-InstalledPayload -InstallDirectory $installDirectory -PayloadDirectory $tempRoot
    Assert-InstalledMetadata -UninstallKeyPaths $uninstallKeyPaths -ExpectedVersion $expectedVersion
    if (-not (Test-Path -LiteralPath $startMenuShortcut -PathType Leaf)) {
        Fail-InstalledFat "KVM Switcher Start Menu shortcut is missing"
    }
    if ((Get-StartupValue).Present) {
        Fail-InstalledFat "startup value was enabled on fresh install"
    }
    Assert-ConfigUnchanged -Before $configBefore -After (Get-ConfigState -Path $configPath)

    $installedExe = Join-Path $installDirectory "KvmSwitcher.exe"
    $probeExit = Invoke-BoundedProcess -FilePath $installedExe -Arguments @("--probe-hardware") -TimeoutMilliseconds 15000 -Label "installed hardware probe"
    if ($probeExit -ne 0) {
        Fail-InstalledFat ("installed hardware probe returned exit code " + $probeExit)
    }
    Assert-ConfigUnchanged -Before $configBefore -After (Get-ConfigState -Path $configPath)

    $reinstallExit = Invoke-BoundedProcess -FilePath $setupPath -Arguments @("/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART", "/SP-", '/TASKS="startup"') -TimeoutMilliseconds 120000 -Label "reinstall smoke"
    if ($reinstallExit -ne 0) {
        Fail-InstalledFat ("reinstall smoke returned exit code " + $reinstallExit)
    }
    Assert-InstalledPayload -InstallDirectory $installDirectory -PayloadDirectory $tempRoot
    Assert-InstalledMetadata -UninstallKeyPaths $uninstallKeyPaths -ExpectedVersion $expectedVersion
    $startup = Get-StartupValue
    $expectedStartup = '"' + $installedExe + '"'
    if (-not $startup.Present -or $startup.Value -ne $expectedStartup) {
        Fail-InstalledFat "reinstall startup value is not the exact quoted installed path"
    }
    Assert-ConfigUnchanged -Before $configBefore -After (Get-ConfigState -Path $configPath)

    $uninstallerPath = Join-Path $installDirectory "unins000.exe"
    $uninstallExit = Invoke-BoundedProcess -FilePath $uninstallerPath -Arguments @("/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART") -TimeoutMilliseconds 120000 -Label "uninstaller"
    if ($uninstallExit -ne 0) {
        Fail-InstalledFat ("uninstaller returned exit code " + $uninstallExit)
    }
    Wait-ForPathRemoval -Path $installDirectory -TimeoutMilliseconds 5000
    if (Test-Path -LiteralPath $installDirectory) {
        Fail-InstalledFat "install directory remains after uninstall"
    }
    Assert-NoUninstallEntry -KeyPaths $uninstallKeyPaths
    if (Test-Path -LiteralPath $startMenuShortcut) {
        Fail-InstalledFat "Start Menu shortcut remains after uninstall"
    }
    if ((Get-StartupValue).Present) {
        Fail-InstalledFat "startup value remains after uninstall"
    }
    Assert-ConfigUnchanged -Before $configBefore -After (Get-ConfigState -Path $configPath)

    $utc = [DateTime]::UtcNow.ToString("o", [System.Globalization.CultureInfo]::InvariantCulture)
    Write-Host "PASS: installed-product automated FAT" -ForegroundColor Green
    Write-Host ("  UTC: " + $utc)
    Write-Host ("  Version: " + $expectedVersion)
    Write-Host ("  ZIP SHA256: " + $manifest["KvmSwitcher-win-x64.zip"])
    Write-Host ("  Setup SHA256: " + $manifest["KvmSwitcher-Setup.exe"])
    Write-Host ("  Online installer SHA256: " + $manifest["install-kvm-switcher.sh"])
    Write-Host ("  Debian fallback bundle SHA256: " + $manifest["kvm-switcher-debian.zip"])
    Write-Host "  Preflight: pass; Install: pass; Probe: pass; Reinstall smoke: pass; Uninstall: pass; Config: preserved"
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
    Write-Host ("FAIL: installed-product automated FAT - " + $failureMessage) -ForegroundColor Red
    Write-Host "Installed state was not automatically cleaned; inspect and clean it deliberately before rerunning." -ForegroundColor Yellow
    exit 1
}
