[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2.0

function Fail-Installer {
    param([string]$Message)
    Write-Host ("FAIL: " + $Message) -ForegroundColor Red
    exit 1
}

function Invoke-CommandChecked {
    param(
        [string]$Label,
        [string]$FilePath,
        [string[]]$Arguments,
        [string]$WorkingDirectory
    )

    Write-Host ("> " + $Label)
    Push-Location -LiteralPath $WorkingDirectory
    try {
        & $FilePath @Arguments
        $exitCode = $LASTEXITCODE
    }
    catch {
        Pop-Location
        Fail-Installer ($Label + " could not start")
    }
    Pop-Location
    if ($exitCode -ne 0) {
        Fail-Installer ($Label + " failed with exit code " + $exitCode)
    }
}

function Assert-File {
    param([string]$Path, [string]$Label)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Fail-Installer ("Missing " + $Label)
    }
}

function Find-Iscc {
    $command = Get-Command ISCC.exe -ErrorAction SilentlyContinue
    if ($null -ne $command) {
        return $command.Source
    }

    $candidates = @(
        (Join-Path ${env:ProgramFiles(x86)} "Inno Setup 6\ISCC.exe"),
        (Join-Path $env:ProgramFiles "Inno Setup 6\ISCC.exe")
    )
    $appPathKeys = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\ISCC.exe",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths\ISCC.exe",
        "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\ISCC.exe"
    )
    foreach ($key in $appPathKeys) {
        if (Test-Path -LiteralPath $key) {
            $properties = Get-ItemProperty -LiteralPath $key
            $defaultPath = $properties.'(default)'
            if (-not [string]::IsNullOrWhiteSpace($defaultPath)) {
                $candidates += [string]$defaultPath
            }
        }
    }

    foreach ($candidate in $candidates) {
        if (-not [string]::IsNullOrWhiteSpace($candidate) -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            return $candidate
        }
    }
    return $null
}

$scriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = (Resolve-Path (Join-Path $scriptDirectory "..")).Path
$staging = Join-Path $repoRoot "artifacts\staging\windows"
$artifactRoot = Join-Path $repoRoot "artifacts"
$iss = Join-Path $repoRoot "installer\KvmSwitcher.iss"
$setup = Join-Path $artifactRoot "KvmSwitcher-Setup.exe"

New-Item -ItemType Directory -Path $artifactRoot -Force | Out-Null
if (-not (Test-Path -LiteralPath $staging -PathType Container)) {
    Fail-Installer "Existing publish staging directory is required"
}
Assert-File -Path $iss -Label "Inno Setup script"

$requiredFiles = @("KvmSwitcher.exe", "KvmSwitcher.dll", "KvmSwitcher.deps.json", "KvmSwitcher.runtimeconfig.json", "HidSharp.dll", "kvm-switcher_0.8.2-1_all.deb", "LICENSE", "THIRD-PARTY-NOTICES.txt")
foreach ($fileName in $requiredFiles) {
    Assert-File -Path (Join-Path $staging $fileName) -Label ("published " + $fileName)
}
foreach ($file in @(Get-ChildItem -LiteralPath $staging -File)) {
    if ($requiredFiles -notcontains $file.Name) {
        Fail-Installer ("Unexpected publish file: " + $file.Name)
    }
}
if (@(Get-ChildItem -LiteralPath $staging -Directory -Recurse).Count -ne 0) {
    Fail-Installer "Unexpected publish directory"
}

$fileVersion = [Diagnostics.FileVersionInfo]::GetVersionInfo((Join-Path $staging "KvmSwitcher.exe")).FileVersion
if ($fileVersion -notmatch '^\d+\.\d+\.\d+\.\d+$') {
    Fail-Installer "Published EXE has no numeric four-part file version"
}

$iscc = Find-Iscc
if ([string]::IsNullOrWhiteSpace($iscc)) {
    Fail-Installer "ISCC.exe was not found on PATH, in standard Inno Setup locations, or App Paths"
}
if (Test-Path -LiteralPath $setup) {
    Remove-Item -LiteralPath $setup -Force
}
Invoke-CommandChecked -Label "Inno Setup compile" -FilePath $iscc -WorkingDirectory $repoRoot -Arguments @(
    "/DAppVersion=$fileVersion", $iss
)
Assert-File -Path $setup -Label "installer output"
if ((Get-Item -LiteralPath $setup).Length -le 0) {
    Fail-Installer "Installer output is empty"
}

Write-Host "PASS: KvmSwitcher-Setup.exe built" -ForegroundColor Green
Write-Host ("  Version: " + $fileVersion)
Write-Host ("  Output: " + $setup)
