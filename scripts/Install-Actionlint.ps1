[CmdletBinding()]
param(
    [string]$InstallRoot = (
        Join-Path (Split-Path $PSScriptRoot -Parent) ".tools/actionlint"
    ),

    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path $PSScriptRoot -Parent
$ConfigPath = Join-Path $RepoRoot "config/actionlint.json"

if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
    throw "actionlint configuration not found: $ConfigPath"
}

$Config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json

if ($Config.version -notmatch '^\d+\.\d+\.\d+$') {
    throw "Invalid actionlint version in: $ConfigPath"
}

$OperatingSystem = if (
    [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform(
        [System.Runtime.InteropServices.OSPlatform]::Windows
    )
) {
    "windows"
}
elseif (
    [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform(
        [System.Runtime.InteropServices.OSPlatform]::Linux
    )
) {
    "linux"
}
elseif (
    [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform(
        [System.Runtime.InteropServices.OSPlatform]::OSX
    )
) {
    "macos"
}
else {
    throw "Unsupported operating system."
}

$Architecture = switch (
    [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture
) {
    "X64" { "x64" }
    "Arm64" { "arm64" }
    default {
        throw "Unsupported architecture: $($_.ToString())"
    }
}

$PlatformKey = "$OperatingSystem-$Architecture"
$ArtifactProperty = $Config.artifacts.PSObject.Properties[$PlatformKey]

if ($null -eq $ArtifactProperty) {
    throw "No actionlint artifact is configured for: $PlatformKey"
}

$Artifact = $ArtifactProperty.Value

if ($Artifact.sha256 -notmatch '^[a-f0-9]{64}$') {
    throw "Invalid SHA-256 for actionlint platform: $PlatformKey"
}

$VersionRoot = Join-Path $InstallRoot $Config.version
$ExecutableName = if ($OperatingSystem -eq "windows") {
    "actionlint.exe"
}
else {
    "actionlint"
}
$ExecutablePath = Join-Path $VersionRoot $ExecutableName

if ((Test-Path -LiteralPath $ExecutablePath -PathType Leaf) -and -not $Force) {
    $InstalledVersion = (& $ExecutablePath -version) -join [Environment]::NewLine

    if ($LASTEXITCODE -ne 0 -or $InstalledVersion -notmatch $Config.version) {
        throw "The installed actionlint executable is invalid. Re-run with -Force."
    }

    Write-Output $ExecutablePath
    return
}

$DownloadRootName = "skills-utils-actionlint-$([guid]::NewGuid().ToString('N'))"
$DownloadRoot = Join-Path ([System.IO.Path]::GetTempPath()) $DownloadRootName
$ArchivePath = Join-Path $DownloadRoot $Artifact.file
$ExtractRoot = Join-Path $DownloadRoot "extracted"
$DownloadUri = "https://github.com/rhysd/actionlint/releases/download/v$($Config.version)/$($Artifact.file)"

New-Item -ItemType Directory -Path $ExtractRoot -Force | Out-Null

try {
    Write-Verbose "Downloading actionlint $($Config.version) from $DownloadUri"
    Invoke-WebRequest -Uri $DownloadUri -OutFile $ArchivePath

    $ActualHash = (Get-FileHash -LiteralPath $ArchivePath -Algorithm SHA256).Hash

    if ($ActualHash -ne $Artifact.sha256) {
        throw "actionlint archive checksum verification failed for $PlatformKey."
    }

    if ($Artifact.file.EndsWith(".zip", [System.StringComparison]::Ordinal)) {
        Expand-Archive -LiteralPath $ArchivePath -DestinationPath $ExtractRoot
    }
    elseif (
        $Artifact.file.EndsWith(
            ".tar.gz",
            [System.StringComparison]::Ordinal
        )
    ) {
        if (-not (Get-Command tar -ErrorAction SilentlyContinue)) {
            throw "The tar command is required to extract: $($Artifact.file)"
        }

        & tar -xzf $ArchivePath -C $ExtractRoot

        if ($LASTEXITCODE -ne 0) {
            throw "Failed to extract actionlint archive: $ArchivePath"
        }
    }
    else {
        throw "Unsupported actionlint archive type: $($Artifact.file)"
    }

    $ExtractedExecutable = Get-ChildItem `
        -LiteralPath $ExtractRoot `
        -Filter $ExecutableName `
        -File `
        -Recurse |
        Select-Object -First 1

    if ($null -eq $ExtractedExecutable) {
        throw "actionlint executable not found in: $($Artifact.file)"
    }

    New-Item -ItemType Directory -Path $VersionRoot -Force | Out-Null
    Copy-Item `
        -LiteralPath $ExtractedExecutable.FullName `
        -Destination $ExecutablePath `
        -Force

    if ($OperatingSystem -ne "windows") {
        & chmod +x $ExecutablePath

        if ($LASTEXITCODE -ne 0) {
            throw "Failed to mark actionlint as executable: $ExecutablePath"
        }
    }

    $InstalledVersion = (& $ExecutablePath -version) -join [Environment]::NewLine

    if ($LASTEXITCODE -ne 0 -or $InstalledVersion -notmatch $Config.version) {
        throw "The downloaded actionlint executable failed verification."
    }

    Write-Output $ExecutablePath
}
finally {
    $ResolvedTempRoot = [System.IO.Path]::GetFullPath(
        [System.IO.Path]::GetTempPath()
    )
    $ResolvedDownloadRoot = [System.IO.Path]::GetFullPath($DownloadRoot)
    $ResolvedDownloadName = [System.IO.Path]::GetFileName($ResolvedDownloadRoot)

    if (
        -not $ResolvedDownloadRoot.StartsWith(
            $ResolvedTempRoot,
            [System.StringComparison]::OrdinalIgnoreCase
        ) -or
        -not $ResolvedDownloadName.StartsWith(
            "skills-utils-actionlint-",
            [System.StringComparison]::Ordinal
        )
    ) {
        throw "Refusing to remove unexpected download path: $ResolvedDownloadRoot"
    }

    if (Test-Path -LiteralPath $ResolvedDownloadRoot) {
        Remove-Item -LiteralPath $ResolvedDownloadRoot -Recurse -Force
    }
}
