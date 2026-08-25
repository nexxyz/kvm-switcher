[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$Version,
    [string]$ChangelogMessage,
    [string]$RepositoryRoot
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

function Stop-VersionUpdate {
    param([string]$Message)
    throw $Message
}

function Read-TextFile {
    param([string]$Path)
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    return [System.IO.File]::ReadAllText($Path, $utf8)
}

function Write-TextFile {
    param([string]$Path, [string]$Text)
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Text, $utf8)
}

function Get-VersionParts {
    param([string]$Value, [string]$Label)
    if ($Value -notmatch '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$') {
        Stop-VersionUpdate "$Label must be MAJOR.MINOR.PATCH with nonnegative decimal components"
    }
    return @($Matches[1], $Matches[2], $Matches[3])
}

function Compare-VersionParts {
    param([object[]]$Left, [object[]]$Right)
    for ($index = 0; $index -lt 3; $index++) {
        $leftText = [string]$Left[$index]
        $rightText = [string]$Right[$index]
        if ($leftText.Length -lt $rightText.Length) { return -1 }
        if ($leftText.Length -gt $rightText.Length) { return 1 }
        $comparison = [string]::CompareOrdinal($leftText, $rightText)
        if ($comparison -lt 0) { return -1 }
        if ($comparison -gt 0) { return 1 }
    }
    return 0
}

function Add-TokenSpec {
    param(
        [System.Collections.ArrayList]$Specs,
        [string]$RelativePath,
        [object[]]$Replacements
    )
    [void]$Specs.Add([pscustomobject]@{
        RelativePath = $RelativePath
        Replacements = @($Replacements)
    })
}

function Contains-Token {
    param([string]$Text, [string]$Token)
    return $Text.IndexOf($Token, [System.StringComparison]::Ordinal) -ge 0
}

try {
    $targetParts = Get-VersionParts -Value $Version -Label "Version"
    if (-not $PSBoundParameters.ContainsKey("ChangelogMessage")) {
        $ChangelogMessage = "Prepare KVM Switcher $Version."
    }
    elseif ([string]::IsNullOrWhiteSpace($ChangelogMessage)) {
        Stop-VersionUpdate "ChangelogMessage must not be blank"
    }
    if ($ChangelogMessage.IndexOf("`r", [System.StringComparison]::Ordinal) -ge 0 -or
        $ChangelogMessage.IndexOf("`n", [System.StringComparison]::Ordinal) -ge 0) {
        Stop-VersionUpdate "ChangelogMessage must be a single line"
    }
    $ChangelogMessage = $ChangelogMessage.Trim()
    if ([string]::IsNullOrWhiteSpace($ChangelogMessage)) {
        Stop-VersionUpdate "ChangelogMessage must not be blank"
    }

    $scriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
    if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
        $RepositoryRoot = (Resolve-Path (Join-Path $scriptDirectory "..")).Path
    }
    else {
        if (-not (Test-Path -LiteralPath $RepositoryRoot -PathType Container)) {
            Stop-VersionUpdate "RepositoryRoot is not an existing directory"
        }
        $RepositoryRoot = (Resolve-Path -LiteralPath $RepositoryRoot).Path
    }

    $activeRelativePaths = @(
        "src\KvmSwitcher\KvmSwitcher.csproj",
        "src\KvmSwitcher\DebianBundleExporter.cs",
        "tests\KvmSwitcher.Tests\DebianBundleTests.cs",
        "scripts\Build-DebianPackage.sh",
        "scripts\Run-AutomatedFat.ps1",
        "scripts\Run-LiveHardwareFat.ps1",
        "scripts\Run-InstalledProductFat.ps1",
        "scripts\Test-DebianBundleInstall.sh",
        "scripts\Test-DebianAptLifecycle.sh",
        "scripts\Build-OnlineInstaller.sh",
        "scripts\Test-OnlineInstaller.sh",
        "scripts\install-kvm-switcher.sh.in",
        "installer\KvmSwitcher.iss",
        "installer\build-installer.ps1",
        ".github\workflows\ci.yml",
        "linux\pyproject.toml",
        "linux\README.md",
        "linux\debian-bundle\install.sh",
        "linux\debian-bundle\README.md",
        "packaging\debian\README.Debian",
        "README.md",
        "docs\MANUAL_FAT.md",
        "docs\RELEASE.md"
    )
    if (@($activeRelativePaths | Sort-Object -Unique).Count -ne $activeRelativePaths.Count) {
        Stop-VersionUpdate "active release allowlist contains duplicate paths"
    }

    $originalTexts = @{}
    foreach ($relativePath in $activeRelativePaths) {
        $path = Join-Path $RepositoryRoot $relativePath
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            Stop-VersionUpdate "missing active release file: $relativePath"
        }
        $originalTexts[$relativePath] = Read-TextFile -Path $path
    }
    $csprojRelativePath = "src\KvmSwitcher\KvmSwitcher.csproj"
    $pyprojectRelativePath = "linux\pyproject.toml"
    $changelogRelativePath = "packaging\debian\changelog"
    $changelogPath = Join-Path $RepositoryRoot $changelogRelativePath
    if (-not (Test-Path -LiteralPath $changelogPath -PathType Leaf)) {
        Stop-VersionUpdate "missing Debian changelog"
    }
    $changelogText = Read-TextFile -Path $changelogPath

    $csprojMatches = [regex]::Matches(
        $originalTexts[$csprojRelativePath],
        '(?m)^[ \t]*<Version>(?<value>[^<\r\n]+)</Version>[ \t]*\r?$')
    if ($csprojMatches.Count -ne 1) {
        Stop-VersionUpdate "expected exactly one active <Version> in KvmSwitcher.csproj"
    }
    $currentVersion = $csprojMatches[0].Groups["value"].Value
    $currentParts = Get-VersionParts -Value $currentVersion -Label "current project version"

    $pyprojectMatches = [regex]::Matches(
        $originalTexts[$pyprojectRelativePath],
        '(?m)^[ \t]*version = "(?<value>[^"\r\n]+)"[ \t]*\r?$')
    if ($pyprojectMatches.Count -ne 1) {
        Stop-VersionUpdate "expected exactly one active version in linux/pyproject.toml"
    }
    $linuxVersion = $pyprojectMatches[0].Groups["value"].Value
    if ($linuxVersion -cne $currentVersion) {
        Stop-VersionUpdate "Windows and Linux active versions do not match"
    }

    if ((Compare-VersionParts -Left $targetParts -Right $currentParts) -le 0) {
        Stop-VersionUpdate "target version must be strictly greater than current version $currentVersion"
    }

    $firstLineMatch = [regex]::Match($changelogText, '^(?<line>[^\r\n]*)')
    $headerMatch = [regex]::Match(
        $firstLineMatch.Groups["line"].Value,
        '^kvm-switcher \((?<version>(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*))-(?<revision>[1-9][0-9]*)\) unstable; urgency=medium$')
    if (-not $headerMatch.Success -or $headerMatch.Groups["version"].Value -cne $currentVersion) {
        Stop-VersionUpdate "first Debian changelog header does not match current version"
    }
    if ($headerMatch.Groups["revision"].Value -cne "1") {
        Stop-VersionUpdate "current Debian revision must be 1"
    }
    $oldPackageName = "kvm-switcher_${currentVersion}-1_all.deb"
    $newPackageName = "kvm-switcher_${Version}-1_all.deb"
    $oldPackageRegex = $oldPackageName.Replace(".", "\.")
    $newPackageRegex = $newPackageName.Replace(".", "\.")

    $controlPath = Join-Path $RepositoryRoot "packaging\debian\control"
    if (-not (Test-Path -LiteralPath $controlPath -PathType Leaf)) {
        Stop-VersionUpdate "missing Debian control file"
    }
    $controlText = Read-TextFile -Path $controlPath
    $controlMatches = [regex]::Matches($controlText, '(?m)^Package: kvm-switcher\r?$')
    if ($controlMatches.Count -ne 1) {
        Stop-VersionUpdate "Debian control file must use package name kvm-switcher"
    }

    $rootReadmePath = Join-Path $RepositoryRoot "README.md"
    $rootReadmeReplacements = New-Object System.Collections.ArrayList
    if (Test-Path -LiteralPath $rootReadmePath -PathType Leaf) {
        $rootReadme = Read-TextFile -Path $rootReadmePath
        if (Contains-Token -Text $rootReadme -Token $oldPackageName) {
            [void]$rootReadmeReplacements.Add([pscustomobject]@{ Old = $oldPackageName; New = $newPackageName })
        }
        if (Contains-Token -Text $rootReadme -Token $oldPackageRegex) {
            [void]$rootReadmeReplacements.Add([pscustomobject]@{ Old = $oldPackageRegex; New = $newPackageRegex })
        }
        if ($rootReadmeReplacements.Count -gt 0) {
            $originalTexts["README.md"] = $rootReadme
        }
    }

    $specs = New-Object System.Collections.ArrayList
    Add-TokenSpec -Specs $specs -RelativePath $csprojRelativePath -Replacements @(
        [pscustomobject]@{ Old = "<Version>$currentVersion</Version>"; New = "<Version>$Version</Version>" },
        [pscustomobject]@{ Old = "<FileVersion>$currentVersion.0</FileVersion>"; New = "<FileVersion>$Version.0</FileVersion>" },
        [pscustomobject]@{ Old = "<AssemblyVersion>$currentVersion.0</AssemblyVersion>"; New = "<AssemblyVersion>$Version.0</AssemblyVersion>" }
    )
    Add-TokenSpec -Specs $specs -RelativePath $pyprojectRelativePath -Replacements @(
        [pscustomobject]@{ Old = ('version = "' + $currentVersion + '"'); New = ('version = "' + $Version + '"') }
    )
    Add-TokenSpec -Specs $specs -RelativePath "scripts\Build-DebianPackage.sh" -Replacements @(
        [pscustomobject]@{ Old = $currentVersion; New = $Version }
    )

    $packageTokenPaths = @(
        "src\KvmSwitcher\DebianBundleExporter.cs",
        "tests\KvmSwitcher.Tests\DebianBundleTests.cs",
        "scripts\Run-AutomatedFat.ps1",
        "scripts\Run-LiveHardwareFat.ps1",
        "scripts\Run-InstalledProductFat.ps1",
        "scripts\Test-DebianBundleInstall.sh",
        "scripts\Build-OnlineInstaller.sh",
        "scripts\Test-OnlineInstaller.sh",
        "scripts\install-kvm-switcher.sh.in",
        "installer\KvmSwitcher.iss",
        "installer\build-installer.ps1",
        ".github\workflows\ci.yml",
        "linux\README.md",
        "linux\debian-bundle\install.sh",
        "linux\debian-bundle\README.md",
        "packaging\debian\README.Debian",
        "docs\MANUAL_FAT.md",
        "docs\RELEASE.md"
    )
    foreach ($relativePath in $packageTokenPaths) {
        Add-TokenSpec -Specs $specs -RelativePath $relativePath -Replacements @(
            [pscustomobject]@{ Old = $oldPackageName; New = $newPackageName }
        )
    }
    foreach ($relativePath in @("scripts\Run-AutomatedFat.ps1", ".github\workflows\ci.yml")) {
        Add-TokenSpec -Specs $specs -RelativePath $relativePath -Replacements @(
            [pscustomobject]@{ Old = $oldPackageRegex; New = $newPackageRegex }
        )
    }

    $tagTokenPaths = @(
        "scripts\Build-OnlineInstaller.sh",
        "scripts\Test-OnlineInstaller.sh",
        "README.md",
        "docs\MANUAL_FAT.md",
        "docs\RELEASE.md"
    )
    foreach ($relativePath in $tagTokenPaths) {
        if ($activeRelativePaths -notcontains $relativePath) {
            Stop-VersionUpdate "tag token specification is outside the active release allowlist: $relativePath"
        }
    }
    $oldTag = "v$currentVersion"
    $newTag = "v$Version"
    foreach ($relativePath in $tagTokenPaths) {
        Add-TokenSpec -Specs $specs -RelativePath $relativePath -Replacements @(
            [pscustomobject]@{ Old = $oldTag; New = $newTag }
        )
    }

    if ($rootReadmeReplacements.Count -gt 0) {
        Add-TokenSpec -Specs $specs -RelativePath "README.md" -Replacements @($rootReadmeReplacements.ToArray())
    }

    $specPaths = @($specs | ForEach-Object { $_.RelativePath })
    foreach ($specPath in $specPaths) {
        if ($activeRelativePaths -notcontains $specPath) {
            Stop-VersionUpdate "token specification is outside the active release allowlist: $specPath"
        }
    }
    $candidateTexts = @{}
    foreach ($relativePath in $activeRelativePaths) {
        $candidateTexts[$relativePath] = $originalTexts[$relativePath]
    }
    $changedRelativePaths = New-Object System.Collections.ArrayList
    foreach ($spec in $specs) {
        $candidate = $candidateTexts[$spec.RelativePath]
        foreach ($replacement in $spec.Replacements) {
            if (-not (Contains-Token -Text $candidate -Token $replacement.Old)) {
                Stop-VersionUpdate "expected token is missing in $($spec.RelativePath)"
            }
            $candidate = $candidate.Replace($replacement.Old, $replacement.New)
        }
        if ($candidate -ne $candidateTexts[$spec.RelativePath]) {
            $candidateTexts[$spec.RelativePath] = $candidate
            if (-not ($changedRelativePaths -contains $spec.RelativePath)) {
                [void]$changedRelativePaths.Add($spec.RelativePath)
            }
        }
    }

    $newline = "`n"
    if ($changelogText.Contains("`r`n")) {
        $newline = "`r`n"
    }
    elseif ($changelogText.Contains("`r")) {
        $newline = "`r"
    }
    $debianDate = [DateTime]::UtcNow.ToString(
        "ddd, dd MMM yyyy HH:mm:ss +0000",
        [Globalization.CultureInfo]::InvariantCulture)
    $newHeader = "kvm-switcher ($Version-1) unstable; urgency=medium"
    $newChangelogEntry = $newHeader + $newline + $newline +
        "  * " + $ChangelogMessage + $newline + $newline +
        " -- nexxyz <nexxyz@users.noreply.github.com>  " + $debianDate + $newline + $newline
    $candidateChangelog = $newChangelogEntry + $changelogText
    if (-not $candidateChangelog.StartsWith($newHeader, [System.StringComparison]::Ordinal)) {
        Stop-VersionUpdate "new Debian changelog entry could not be prepared"
    }
    if ($candidateChangelog.Substring($newChangelogEntry.Length) -cne $changelogText) {
        Stop-VersionUpdate "existing Debian changelog history would not be preserved"
    }

    $candidateTexts[$changelogRelativePath] = $candidateChangelog
    [void]$changedRelativePaths.Add($changelogRelativePath)

    foreach ($relativePath in $activeRelativePaths) {
        $candidate = $candidateTexts[$relativePath]
        foreach ($oldToken in @($oldPackageName, $oldPackageRegex)) {
            if (Contains-Token -Text $candidate -Token $oldToken) {
                Stop-VersionUpdate "old active token remains in $relativePath"
            }
        }
    }
    foreach ($relativePath in $tagTokenPaths) {
        if (Contains-Token -Text $candidateTexts[$relativePath] -Token $oldTag) {
            Stop-VersionUpdate "old release tag remains in $relativePath"
        }
    }
    $newPackageFound = $false
    foreach ($relativePath in $activeRelativePaths) {
        if (Contains-Token -Text $candidateTexts[$relativePath] -Token $newPackageName) {
            $newPackageFound = $true
            break
        }
    }
    if (-not $newPackageFound) {
        Stop-VersionUpdate "new package filename is absent from the active release surface"
    }

    $finalCsproj = $candidateTexts[$csprojRelativePath]
    $finalVersionMatches = [regex]::Matches($finalCsproj, '(?m)^[ \t]*<Version>(?<value>[^<\r\n]+)</Version>[ \t]*\r?$')
    $finalFileVersionMatches = [regex]::Matches($finalCsproj, '(?m)^[ \t]*<FileVersion>(?<value>[^<\r\n]+)</FileVersion>[ \t]*\r?$')
    $finalAssemblyVersionMatches = [regex]::Matches($finalCsproj, '(?m)^[ \t]*<AssemblyVersion>(?<value>[^<\r\n]+)</AssemblyVersion>[ \t]*\r?$')
    if ($finalVersionMatches.Count -ne 1 -or $finalVersionMatches[0].Groups["value"].Value -cne $Version -or
        $finalFileVersionMatches.Count -ne 1 -or $finalFileVersionMatches[0].Groups["value"].Value -cne "$Version.0" -or
        $finalAssemblyVersionMatches.Count -ne 1 -or $finalAssemblyVersionMatches[0].Groups["value"].Value -cne "$Version.0") {
        Stop-VersionUpdate "final Windows version fields are inconsistent"
    }
    $finalPyprojectMatches = [regex]::Matches($candidateTexts[$pyprojectRelativePath], '(?m)^[ \t]*version = "(?<value>[^"\r\n]+)"[ \t]*\r?$')
    if ($finalPyprojectMatches.Count -ne 1 -or $finalPyprojectMatches[0].Groups["value"].Value -cne $Version) {
        Stop-VersionUpdate "final Linux version is inconsistent"
    }

    foreach ($relativePath in $changedRelativePaths) {
        $path = Join-Path $RepositoryRoot $relativePath
        if ($relativePath -eq $changelogRelativePath) {
            Write-TextFile -Path $path -Text $candidateChangelog
        }
        else {
            Write-TextFile -Path $path -Text $candidateTexts[$relativePath]
        }
    }

    foreach ($relativePath in $changedRelativePaths) {
        $actual = Read-TextFile -Path (Join-Path $RepositoryRoot $relativePath)
        if ($actual -cne $candidateTexts[$relativePath]) {
            Stop-VersionUpdate "post-write content differs from the validated candidate: $relativePath"
        }
    }

    $postCsproj = Read-TextFile -Path (Join-Path $RepositoryRoot $csprojRelativePath)
    $postPyproject = Read-TextFile -Path (Join-Path $RepositoryRoot $pyprojectRelativePath)
    $postChangelog = Read-TextFile -Path $changelogPath
    $postCsprojVersion = [regex]::Matches($postCsproj, '(?m)^[ \t]*<Version>(?<value>[^<\r\n]+)</Version>[ \t]*\r?$')
    $postCsprojFileVersion = [regex]::Matches($postCsproj, '(?m)^[ \t]*<FileVersion>(?<value>[^<\r\n]+)</FileVersion>[ \t]*\r?$')
    $postCsprojAssemblyVersion = [regex]::Matches($postCsproj, '(?m)^[ \t]*<AssemblyVersion>(?<value>[^<\r\n]+)</AssemblyVersion>[ \t]*\r?$')
    $postPyprojectVersion = [regex]::Matches($postPyproject, '(?m)^[ \t]*version = "(?<value>[^"\r\n]+)"[ \t]*\r?$')
    if ($postCsprojVersion.Count -ne 1 -or $postCsprojVersion[0].Groups["value"].Value -cne $Version -or
        $postCsprojFileVersion.Count -ne 1 -or $postCsprojFileVersion[0].Groups["value"].Value -cne "$Version.0" -or
        $postCsprojAssemblyVersion.Count -ne 1 -or $postCsprojAssemblyVersion[0].Groups["value"].Value -cne "$Version.0" -or
        $postPyprojectVersion.Count -ne 1 -or $postPyprojectVersion[0].Groups["value"].Value -cne $Version) {
        Stop-VersionUpdate "post-write project versions do not agree"
    }
    if (-not $postChangelog.StartsWith($newHeader, [System.StringComparison]::Ordinal)) {
        Stop-VersionUpdate "post-write Debian changelog header is incorrect"
    }

    Write-Host "Updated version $currentVersion to $Version"
    Write-Host "Debian package: $newPackageName"
    Write-Host "Changed files:"
    foreach ($relativePath in $changedRelativePaths) {
        Write-Host (" - " + $relativePath)
    }
    Write-Host "Next command: scripts/Run-AutomatedFat.ps1"
    exit 0
}
catch {
    [Console]::Error.WriteLine("Set-Version: " + $_.Exception.Message)
    exit 1
}
