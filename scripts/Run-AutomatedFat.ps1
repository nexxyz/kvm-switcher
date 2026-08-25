[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2.0

function Fail-Fat {
    param([string]$Message)
    Write-Host ("FAIL: " + $Message) -ForegroundColor Red
    exit 1
}

function Assert-File {
    param([string]$Path, [string]$Label)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Fail-Fat ("Missing " + $Label + ": " + $Path)
    }
}

function Assert-PowerShellScript {
    param([string]$Path)

    foreach ($byte in [System.IO.File]::ReadAllBytes($Path)) {
        if ($byte -gt 127) {
            Fail-Fat "PowerShell FAT script contains non-ASCII bytes"
        }
    }

    $tokens = $null
    $parseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile(
        $Path,
        [ref]$tokens,
        [ref]$parseErrors) | Out-Null
    if ($null -ne $parseErrors -and @($parseErrors).Count -ne 0) {
        Fail-Fat "PowerShell FAT script contains syntax errors"
    }
}

function Assert-ExactOnlineBundle {
    param([string]$Path)

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $expectedEntries = @("kvm-switcher_0.8.1-1_all.deb", "config.json", "install.sh", "README.md", "LICENSE", "SHA256SUMS")
    $archive = [System.IO.Compression.ZipFile]::OpenRead($Path)
    try {
        $entries = @($archive.Entries)
        if ($entries.Count -ne $expectedEntries.Count) {
            Fail-Fat "Debian online fallback bundle does not contain exactly six entries"
        }
        foreach ($entry in $entries) {
            if ($entry.FullName.EndsWith("/") -or $expectedEntries -notcontains $entry.FullName -or $entry.Length -le 0) {
                Fail-Fat "Debian online fallback bundle contains an invalid entry"
            }
        }
    }
    finally {
        $archive.Dispose()
    }
}

function Invoke-Tool {
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
        Fail-Fat ($Label + " could not start: " + $_.Exception.Message)
    }
    Pop-Location

    if ($exitCode -ne 0) {
        Fail-Fat ($Label + " failed with exit code " + $exitCode)
    }
}

function Scan-StaleBranding {
    param([string]$Root)

    $patterns = @(
        "MsiKvmSwitcher",
        "MSI KVM Switcher",
        "Msi KVM Switcher",
        "MsiKvmSwitcher\.ico"
    )
    $regex = ($patterns -join "|")
    $extensions = @(".cs", ".csproj", ".sln", ".md", ".json", ".ps1", ".py", ".sh", ".rules", ".txt", ".xml", ".config")
    $files = @()
    if (Test-Path -LiteralPath $Root -PathType Leaf) {
        $files = @(Get-Item -LiteralPath $Root)
    }
    else {
        foreach ($entry in @(Get-ChildItem -LiteralPath $Root -Force -Recurse)) {
            if ($entry.Name -match $regex) {
                Fail-Fat ("Stale branding in release surface path: " + $entry.FullName)
            }
        }
        $files = @(Get-ChildItem -LiteralPath $Root -File -Recurse | Where-Object { $extensions -contains $_.Extension.ToLowerInvariant() })
    }

    foreach ($file in $files) {
        $text = [System.IO.File]::ReadAllText($file.FullName)
        if ($text -match $regex) {
            Fail-Fat ("Stale branding in release surface: " + $file.FullName)
        }
    }
}

$scriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = (Resolve-Path (Join-Path $scriptDirectory "..")).Path
$artifactRoot = Join-Path $repoRoot "artifacts"
$stagingRoot = Join-Path $artifactRoot "staging"
$publishRoot = Join-Path $stagingRoot "windows"

if (Test-Path -LiteralPath $artifactRoot) {
    Remove-Item -LiteralPath $artifactRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $publishRoot -Force | Out-Null

$requiredPaths = @(
    @{ Path = (Join-Path $repoRoot "KvmSwitcher.sln"); Label = "solution" },
    @{ Path = (Join-Path $repoRoot "src\KvmSwitcher\KvmSwitcher.csproj"); Label = "Windows project" },
    @{ Path = (Join-Path $repoRoot "tests\KvmSwitcher.Tests\KvmSwitcher.Tests.csproj"); Label = "test project" },
    @{ Path = (Join-Path $repoRoot "linux\kvmSwitcher.py"); Label = "portable Python CLI" },
    @{ Path = (Join-Path $repoRoot "linux\pyproject.toml"); Label = "portable Python project" },
    @{ Path = (Join-Path $repoRoot "linux\requirements.txt"); Label = "portable requirements" },
    @{ Path = (Join-Path $repoRoot "linux\install.sh"); Label = "portable installer" },
    @{ Path = (Join-Path $repoRoot "linux\README.md"); Label = "portable README" },
    @{ Path = (Join-Path $repoRoot "linux\udev\99-kvm-switcher.rules"); Label = "canonical udev rule" },
    @{ Path = (Join-Path $repoRoot "assets\KvmSwitcher.ico"); Label = "neutral source icon" },
    @{ Path = (Join-Path $repoRoot "README.md"); Label = "release README" },
    @{ Path = (Join-Path $repoRoot "AGENTS.md"); Label = "repository instructions" },
    @{ Path = (Join-Path $repoRoot "scripts\Run-LiveHardwareFat.ps1"); Label = "live FAT script" },
    @{ Path = (Join-Path $repoRoot "scripts\Run-InstalledProductFat.ps1"); Label = "installed FAT script" },
    @{ Path = (Join-Path $repoRoot "scripts\Test-DebianBundleInstall.sh"); Label = "Debian bundle behavior test" },
    @{ Path = (Join-Path $repoRoot "scripts\Test-DebianPackageLifecycle.sh"); Label = "Debian package lifecycle test" },
    @{ Path = (Join-Path $repoRoot "scripts\Test-DebianAptLifecycle.sh"); Label = "optional Debian apt lifecycle test" },
    @{ Path = (Join-Path $repoRoot "installer\KvmSwitcher.iss"); Label = "Inno Setup script" },
    @{ Path = (Join-Path $repoRoot "installer\build-installer.ps1"); Label = "installer build script" },
    @{ Path = (Join-Path $repoRoot "scripts\Build-DebianPackage.sh"); Label = "Debian package build script" },
    @{ Path = (Join-Path $repoRoot "scripts\Build-OnlineInstaller.sh"); Label = "online Debian asset build script" },
    @{ Path = (Join-Path $repoRoot "scripts\Test-OnlineInstaller.sh"); Label = "online Debian asset behavior test" },
    @{ Path = (Join-Path $repoRoot "scripts\install-kvm-switcher.sh.in"); Label = "online Debian installer template" },
    @{ Path = (Join-Path $repoRoot "LICENSE"); Label = "project license" },
    @{ Path = (Join-Path $repoRoot "THIRD-PARTY-NOTICES.txt"); Label = "third-party notices" },
    @{ Path = (Join-Path $repoRoot "packaging\debian\control"); Label = "Debian control input" },
    @{ Path = (Join-Path $repoRoot "packaging\debian\config.json"); Label = "Frozen Debian config input" },
    @{ Path = (Join-Path $repoRoot "packaging\debian\DEBIAN\conffiles"); Label = "Debian conffiles input" },
    @{ Path = (Join-Path $repoRoot "packaging\debian\DEBIAN\postinst"); Label = "Debian postinst input" },
    @{ Path = (Join-Path $repoRoot "packaging\debian\usr\bin\kvm-switch"); Label = "Debian launcher input" },
    @{ Path = (Join-Path $repoRoot "packaging\debian\usr\lib\udev\rules.d\60-kvm-switcher.rules"); Label = "Debian udev input" },
    @{ Path = (Join-Path $repoRoot "packaging\debian\README.Debian"); Label = "Debian README input" },
    @{ Path = (Join-Path $repoRoot "packaging\debian\usr\share\doc\kvm-switcher\copyright"); Label = "Debian copyright input" }
)
foreach ($required in $requiredPaths) {
    Assert-File -Path $required.Path -Label $required.Label
}
Assert-PowerShellScript -Path (Join-Path $repoRoot "scripts\Run-LiveHardwareFat.ps1")
Assert-PowerShellScript -Path (Join-Path $repoRoot "scripts\Run-InstalledProductFat.ps1")
Assert-PowerShellScript -Path (Join-Path $repoRoot "installer\build-installer.ps1")

$forbiddenRepositoryPaths = @(".opencode", ".slim", "lab", "openspec", "poc", "research")
foreach ($relativePath in $forbiddenRepositoryPaths) {
    $candidate = Join-Path $repoRoot $relativePath
    if (Test-Path -LiteralPath $candidate) {
        Fail-Fat ("Internal work path remains in release repository: " + $relativePath)
    }
}

Scan-StaleBranding -Root (Join-Path $repoRoot "src")
Scan-StaleBranding -Root (Join-Path $repoRoot "tests")
Scan-StaleBranding -Root (Join-Path $repoRoot "linux")
Scan-StaleBranding -Root (Join-Path $repoRoot "README.md")
Scan-StaleBranding -Root (Join-Path $repoRoot "KvmSwitcher.sln")

$dotnetCommand = Get-Command dotnet.exe -ErrorAction SilentlyContinue
if ($null -eq $dotnetCommand) {
    Fail-Fat "dotnet.exe is required"
}
$dotnet = $dotnetCommand.Source

Invoke-Tool -Label "dotnet restore" -FilePath $dotnet -Arguments @("restore", "KvmSwitcher.sln") -WorkingDirectory $repoRoot
Invoke-Tool -Label "Release build with warnings as errors" -FilePath $dotnet -Arguments @("build", "KvmSwitcher.sln", "-c", "Release", "-warnaserror", "--no-restore") -WorkingDirectory $repoRoot
$testResultsRoot = Join-Path $artifactRoot "test-results"
New-Item -ItemType Directory -Path $testResultsRoot -Force | Out-Null
Invoke-Tool -Label "Release tests" -FilePath $dotnet -Arguments @("test", "KvmSwitcher.sln", "-c", "Release", "--no-build", "--no-restore", "--logger", "trx;LogFileName=KvmSwitcher.trx", "--results-directory", $testResultsRoot) -WorkingDirectory $repoRoot
$trxFiles = @(Get-ChildItem -LiteralPath $testResultsRoot -File -Filter "*.trx")
if ($trxFiles.Count -ne 1) {
    Fail-Fat ("Expected one TRX test result, found " + $trxFiles.Count)
}
$trxDocument = [xml][System.IO.File]::ReadAllText($trxFiles[0].FullName)
$unitResults = @($trxDocument.TestRun.Results.UnitTestResult)
$totalTests = $unitResults.Count
$failedTests = @($unitResults | Where-Object { $_.outcome -eq "Failed" }).Count
if ($totalTests -le 0) {
    Fail-Fat "TRX reported zero tests"
}
if ($failedTests -ne 0) {
    Fail-Fat ("TRX reported " + $failedTests + " failed test(s)")
}
Write-Host ("TRX tests: " + $totalTests + " total, 0 failed")

$pythonCommand = Get-Command py.exe -ErrorAction SilentlyContinue
$pythonPrefix = @()
if ($null -eq $pythonCommand) {
    $pythonCommand = Get-Command python.exe -ErrorAction SilentlyContinue
}
else {
    $pythonPrefix += "-3"
}
if ($null -eq $pythonCommand) {
    Fail-Fat "Python 3 is required for portable tests"
}
$python = $pythonCommand.Source

$oldNoBytecode = $env:PYTHONDONTWRITEBYTECODE
try {
    $env:PYTHONDONTWRITEBYTECODE = "1"

    $pythonVersionArguments = @($pythonPrefix)
    $pythonVersionArguments += @("-c", "import sys; print('Python {0}.{1}.{2}'.format(*sys.version_info[:3])); raise SystemExit(0 if sys.version_info >= (3, 9) else 1)")
    Invoke-Tool -Label "Python >= 3.9" -FilePath $python -Arguments $pythonVersionArguments -WorkingDirectory (Join-Path $repoRoot "linux")

    $pythonDiscoveryArguments = @($pythonPrefix)
    $pythonDiscoveryArguments += @("-c", "import unittest; suite=unittest.defaultTestLoader.discover('tests', pattern='test_*.py'); count=suite.countTestCases(); print('Discovered Python tests: {}'.format(count)); raise SystemExit(0 if count > 0 else 1)")
    Invoke-Tool -Label "portable Python test discovery count" -FilePath $python -Arguments $pythonDiscoveryArguments -WorkingDirectory (Join-Path $repoRoot "linux")

    $pythonTestArguments = @($pythonPrefix)
    $pythonTestArguments += @("-m", "unittest", "discover", "-s", "tests", "-p", "test_*.py")
    Invoke-Tool -Label "portable Python tests" -FilePath $python -Arguments $pythonTestArguments -WorkingDirectory (Join-Path $repoRoot "linux")
}
finally {
    if ($null -eq $oldNoBytecode) {
        Remove-Item Env:PYTHONDONTWRITEBYTECODE -ErrorAction SilentlyContinue
    }
    else {
        $env:PYTHONDONTWRITEBYTECODE = $oldNoBytecode
    }
}

$pyCompileDirectory = Join-Path $artifactRoot "pycompile"
New-Item -ItemType Directory -Path $pyCompileDirectory -Force | Out-Null
$pycPath = Join-Path $pyCompileDirectory "kvmSwitcher.pyc"
$pyCompileCode = "import py_compile; py_compile.compile('kvmSwitcher.py', cfile=r'$pycPath', doraise=True)"
$pyCompileArguments = @($pythonPrefix)
$pyCompileArguments += @("-c", $pyCompileCode)
Invoke-Tool -Label "portable Python py_compile" -FilePath $python -Arguments $pyCompileArguments -WorkingDirectory (Join-Path $repoRoot "linux")
Remove-Item -LiteralPath $pyCompileDirectory -Recurse -Force

$wslCommand = Get-Command wsl.exe -ErrorAction SilentlyContinue
if ($null -eq $wslCommand) {
    Fail-Fat "WSL is required for local FAT: install/enable WSL, then rerun to validate install.sh with sh -n"
}
$repoRootWithoutSlash = $repoRoot.TrimEnd("\")
$driveLetter = $repoRootWithoutSlash.Substring(0, 1).ToLowerInvariant()
$wslRoot = "/mnt/" + $driveLetter + $repoRootWithoutSlash.Substring(2).Replace("\", "/")
$wslInstallPath = $wslRoot + "/linux/install.sh"
Write-Host "> WSL sh -n linux/install.sh"
& $wslCommand.Source -- sh -n $wslInstallPath
if ($LASTEXITCODE -ne 0) {
    Fail-Fat "WSL is unavailable or sh -n rejected linux/install.sh; install/enable WSL and rerun local FAT"
}
$wslDebianBuildPath = $wslRoot + "/scripts/Build-DebianPackage.sh"
$wslDebianTestPath = $wslRoot + "/scripts/Test-DebianBundleInstall.sh"
$wslDebianLifecyclePath = $wslRoot + "/scripts/Test-DebianPackageLifecycle.sh"
$wslDebianAptLifecyclePath = $wslRoot + "/scripts/Test-DebianAptLifecycle.sh"
$wslOnlineTemplatePath = $wslRoot + "/scripts/install-kvm-switcher.sh.in"
$wslOnlineBuildPath = $wslRoot + "/scripts/Build-OnlineInstaller.sh"
$wslOnlineTestPath = $wslRoot + "/scripts/Test-OnlineInstaller.sh"
Write-Host "> WSL sh -n scripts/Build-DebianPackage.sh"
& $wslCommand.Source -- sh -n $wslDebianBuildPath
if ($LASTEXITCODE -ne 0) {
    Fail-Fat "WSL sh -n rejected the Debian package build script"
}
Write-Host "> WSL sh -n scripts/Test-DebianBundleInstall.sh"
& $wslCommand.Source -- sh -n $wslDebianTestPath
if ($LASTEXITCODE -ne 0) {
    Fail-Fat "WSL sh -n rejected the Debian bundle behavior test"
}
Write-Host "> WSL sh -n scripts/Test-DebianPackageLifecycle.sh"
& $wslCommand.Source -- sh -n $wslDebianLifecyclePath
if ($LASTEXITCODE -ne 0) {
    Fail-Fat "WSL sh -n rejected the Debian package lifecycle test"
}
Write-Host "> WSL sh -n scripts/Test-DebianAptLifecycle.sh"
& $wslCommand.Source -- sh -n $wslDebianAptLifecyclePath
if ($LASTEXITCODE -ne 0) {
    Fail-Fat "WSL sh -n rejected the optional Debian apt lifecycle test"
}
Write-Host "> WSL sh -n online Debian installer lane"
& $wslCommand.Source -- sh -n $wslOnlineTemplatePath $wslOnlineBuildPath $wslOnlineTestPath
if ($LASTEXITCODE -ne 0) {
    Fail-Fat "WSL sh -n rejected the online Debian installer lane"
}
Write-Host "> WSL Debian bundle behavior test"
& $wslCommand.Source -- sh $wslDebianTestPath
if ($LASTEXITCODE -ne 0) {
    Fail-Fat "Debian bundle behavior test failed in WSL"
}
Write-Host "> WSL Debian package build"
& $wslCommand.Source -- sh $wslDebianBuildPath
if ($LASTEXITCODE -ne 0) {
    Fail-Fat "Debian package build failed in WSL"
}
$debianPackagePath = Join-Path $artifactRoot "kvm-switcher_0.8.1-1_all.deb"
$debianSumsPath = Join-Path $artifactRoot "SHA256SUMS-debian.txt"
Assert-File -Path $debianPackagePath -Label "Debian package"
Assert-File -Path $debianSumsPath -Label "Debian SHA256SUMS"
if ((Get-Item -LiteralPath $debianPackagePath).Length -le 0) {
    Fail-Fat "Debian package is empty"
}
$debianSumLines = @(Get-Content -LiteralPath $debianSumsPath | Where-Object { $_.Trim().Length -ne 0 })
if ($debianSumLines.Count -ne 1 -or $debianSumLines[0] -notmatch '^[0-9a-f]{64}\s+kvm-switcher_0\.8\.1-1_all\.deb$') {
    Fail-Fat "Debian SHA256SUMS must contain exactly one lowercase package hash"
}
$debianManifestParts = $debianSumLines[0].Trim() -split "\s+"
$debianActualHash = (Get-FileHash -LiteralPath $debianPackagePath -Algorithm SHA256).Hash.ToLowerInvariant()
if ($debianManifestParts[0] -ne $debianActualHash) {
    Fail-Fat "Debian package hash does not match SHA256SUMS-debian.txt"
}
Write-Host "> WSL Debian package lifecycle fixture (120s deadline)"
& $wslCommand.Source -- sh -c "command -v timeout >/dev/null 2>&1"
if ($LASTEXITCODE -ne 0) {
    Fail-Fat "GNU timeout is required in WSL for the Debian lifecycle fixture"
}
$wslLifecyclePackagePath = $wslRoot + "/artifacts/kvm-switcher_0.8.1-1_all.deb"
& $wslCommand.Source -- timeout 120s sh $wslDebianLifecyclePath $wslLifecyclePackagePath
if ($LASTEXITCODE -ne 0) {
    Fail-Fat "Debian package lifecycle fixture failed or exceeded its 120s deadline"
}
Write-Host "> WSL online Debian release asset build"
& $wslCommand.Source -- sh $wslOnlineBuildPath
if ($LASTEXITCODE -ne 0) {
    Fail-Fat "online Debian release asset build failed in WSL"
}
Write-Host "> WSL online Debian installer behavior test"
& $wslCommand.Source -- sh $wslOnlineTestPath
if ($LASTEXITCODE -ne 0) {
    Fail-Fat "online Debian installer behavior test failed in WSL"
}
$onlineInstallerPath = Join-Path $artifactRoot "install-kvm-switcher.sh"
$debianBundlePath = Join-Path $artifactRoot "kvm-switcher-debian.zip"
Assert-File -Path $onlineInstallerPath -Label "online Debian bootstrap installer"
Assert-File -Path $debianBundlePath -Label "online Debian fallback bundle"
if ((Get-Item -LiteralPath $onlineInstallerPath).Length -le 0 -or
    (Get-Item -LiteralPath $debianBundlePath).Length -le 0) {
    Fail-Fat "online Debian release asset is empty"
}
Assert-ExactOnlineBundle -Path $debianBundlePath

Invoke-Tool -Label "framework-dependent win-x64 publish" -FilePath $dotnet -Arguments @("publish", "src\KvmSwitcher\KvmSwitcher.csproj", "-c", "Release", "-r", "win-x64", "--self-contained", "false", "-o", $publishRoot) -WorkingDirectory $repoRoot
Copy-Item -LiteralPath $debianPackagePath -Destination (Join-Path $publishRoot "kvm-switcher_0.8.1-1_all.deb") -Force
Copy-Item -LiteralPath (Join-Path $repoRoot "LICENSE") -Destination (Join-Path $publishRoot "LICENSE") -Force
Copy-Item -LiteralPath (Join-Path $repoRoot "THIRD-PARTY-NOTICES.txt") -Destination (Join-Path $publishRoot "THIRD-PARTY-NOTICES.txt") -Force

$requiredPublishFiles = @("KvmSwitcher.exe", "KvmSwitcher.dll", "KvmSwitcher.deps.json", "KvmSwitcher.runtimeconfig.json", "HidSharp.dll", "kvm-switcher_0.8.1-1_all.deb", "LICENSE", "THIRD-PARTY-NOTICES.txt")
foreach ($fileName in $requiredPublishFiles) {
    Assert-File -Path (Join-Path $publishRoot $fileName) -Label ("published " + $fileName)
}
Get-ChildItem -LiteralPath $publishRoot -File -Filter "*.pdb" | Remove-Item -Force
$publishFiles = @(Get-ChildItem -LiteralPath $publishRoot -File)
foreach ($publishFile in $publishFiles) {
    if ($requiredPublishFiles -notcontains $publishFile.Name) {
        Fail-Fat ("Unexpected file in Windows publish staging: " + $publishFile.Name)
    }
}
$publishDirectories = @(Get-ChildItem -LiteralPath $publishRoot -Directory -Recurse)
if ($publishDirectories.Count -ne 0) {
    Fail-Fat "Unexpected directory in Windows publish staging"
}

$powershellCommand = Get-Command powershell.exe -ErrorAction SilentlyContinue
if ($null -eq $powershellCommand) {
    Fail-Fat "powershell.exe is required to compile the installer"
}
Invoke-Tool -Label "Inno Setup installer compile" -FilePath $powershellCommand.Source -Arguments @(
    "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", (Join-Path $repoRoot "installer\build-installer.ps1")
) -WorkingDirectory $repoRoot
$setupPath = Join-Path $artifactRoot "KvmSwitcher-Setup.exe"
Assert-File -Path $setupPath -Label "installer output"
if ((Get-Item -LiteralPath $setupPath).Length -le 0) {
    Fail-Fat "Installer output is empty"
}

$zipPath = Join-Path $artifactRoot "KvmSwitcher-win-x64.zip"
Compress-Archive -Path (Join-Path $publishRoot "*") -DestinationPath $zipPath -CompressionLevel Optimal
Assert-File -Path $zipPath -Label "Windows ZIP"

Add-Type -AssemblyName System.IO.Compression.FileSystem
$expectedZipEntries = @("KvmSwitcher.exe", "KvmSwitcher.dll", "KvmSwitcher.deps.json", "KvmSwitcher.runtimeconfig.json", "HidSharp.dll", "kvm-switcher_0.8.1-1_all.deb", "LICENSE", "THIRD-PARTY-NOTICES.txt")
$zip = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
try {
    $zipEntries = @($zip.Entries)
    if ($zipEntries.Count -ne $expectedZipEntries.Count) {
        Fail-Fat ("Windows ZIP has " + $zipEntries.Count + " entries; expected " + $expectedZipEntries.Count)
    }
    foreach ($zipEntry in $zipEntries) {
        if ($zipEntry.FullName.EndsWith("/")) {
            Fail-Fat ("Windows ZIP contains a directory entry: " + $zipEntry.FullName)
        }
        if ($expectedZipEntries -notcontains $zipEntry.FullName) {
            Fail-Fat ("Unexpected Windows ZIP entry: " + $zipEntry.FullName)
        }
        if ($zipEntry.Length -le 0) {
            Fail-Fat ("Empty Windows ZIP entry: " + $zipEntry.FullName)
        }
    }
}
finally {
    $zip.Dispose()
}

$zipHash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
$setupHash = (Get-FileHash -LiteralPath $setupPath -Algorithm SHA256).Hash.ToLowerInvariant()
$onlineInstallerHash = (Get-FileHash -LiteralPath $onlineInstallerPath -Algorithm SHA256).Hash.ToLowerInvariant()
$debianBundleHash = (Get-FileHash -LiteralPath $debianBundlePath -Algorithm SHA256).Hash.ToLowerInvariant()
@(
    ($setupHash + "  KvmSwitcher-Setup.exe"),
    ($zipHash + "  KvmSwitcher-win-x64.zip"),
    ($onlineInstallerHash + "  install-kvm-switcher.sh"),
    ($debianBundleHash + "  kvm-switcher-debian.zip")
) | Set-Content -LiteralPath (Join-Path $artifactRoot "SHA256SUMS.txt") -Encoding ASCII

$manifestPath = Join-Path $artifactRoot "SHA256SUMS.txt"
$manifestExpectedNames = @("KvmSwitcher-Setup.exe", "KvmSwitcher-win-x64.zip", "install-kvm-switcher.sh", "kvm-switcher-debian.zip")
$manifestLines = @(Get-Content -LiteralPath $manifestPath | Where-Object { $_.Trim().Length -ne 0 })
if ($manifestLines.Count -ne $manifestExpectedNames.Count) {
    Fail-Fat "SHA256SUMS.txt must contain exactly four release asset hashes"
}
$manifest = @{}
foreach ($manifestLine in $manifestLines) {
    $manifestParts = $manifestLine.Trim() -split "\s+"
    if ($manifestParts.Count -ne 2 -or
        $manifestParts[0] -notmatch '^[0-9a-f]{64}$' -or
        $manifestExpectedNames -notcontains $manifestParts[1]) {
        Fail-Fat "SHA256SUMS.txt contains an invalid lowercase release asset entry"
    }
    if ($manifest.ContainsKey($manifestParts[1])) {
        Fail-Fat "SHA256SUMS.txt contains a duplicate release asset entry"
    }
    $manifest[$manifestParts[1]] = $manifestParts[0]
}
foreach ($manifestExpectedName in $manifestExpectedNames) {
    if (-not $manifest.ContainsKey($manifestExpectedName)) {
        Fail-Fat "SHA256SUMS.txt is missing an expected release asset entry"
    }
    $manifestAssetPath = Join-Path $artifactRoot $manifestExpectedName
    Assert-File -Path $manifestAssetPath -Label ("manifest asset " + $manifestExpectedName)
    $manifestActualHash = (Get-FileHash -LiteralPath $manifestAssetPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($manifestActualHash -ne $manifest[$manifestExpectedName]) {
        Fail-Fat ("SHA256SUMS.txt hash mismatch for " + $manifestExpectedName)
    }
}

$forbiddenArtifactNames = @("openspec", "research", "lab", "poc", ".slim", ".opencode", "bin", "obj", "__pycache__", ".venv")
foreach ($artifactEntry in @(Get-ChildItem -LiteralPath $artifactRoot -Recurse -Force)) {
    foreach ($forbiddenName in $forbiddenArtifactNames) {
        if ($artifactEntry.FullName.IndexOf($forbiddenName, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
            Fail-Fat ("Forbidden path inside artifacts: " + $artifactEntry.FullName)
        }
    }
}

Write-Host "PASS: automated FAT preparation" -ForegroundColor Green
Write-Host ("  build/test solution: " + (Join-Path $repoRoot "KvmSwitcher.sln"))
Write-Host ("  Windows staging: " + $publishRoot)
Write-Host ("  Windows ZIP: " + $zipPath)
Write-Host ("  Windows setup: " + $setupPath)
Write-Host ("  ZIP SHA256: " + $zipHash)
Write-Host ("  Setup SHA256: " + $setupHash)
Write-Host ("  Debian package: " + $debianPackagePath)
Write-Host ("  Debian SHA256: " + $debianActualHash)
Write-Host ("  Online installer: " + $onlineInstallerPath)
Write-Host ("  Online installer SHA256: " + $onlineInstallerHash)
Write-Host ("  Debian fallback bundle: " + $debianBundlePath)
Write-Host ("  Debian fallback bundle SHA256: " + $debianBundleHash)
