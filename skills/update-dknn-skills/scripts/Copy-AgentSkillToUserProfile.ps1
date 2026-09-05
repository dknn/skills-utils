[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$SourceRoot,

    [string]$TargetRoot = (Join-Path $HOME ".agents"),

    [switch]$RemoveExtraFiles
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Assert-SafeCopyPath {
    param([string]$Path)

    $CurrentPath = [System.IO.Path]::GetFullPath($Path)
    while ($CurrentPath) {
        $Item = Get-Item -LiteralPath $CurrentPath -Force -ErrorAction SilentlyContinue
        if ($null -ne $Item -and ($Item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
            throw "Symbolic links and junctions are not supported: $CurrentPath"
        }
        $CurrentPath = Split-Path $CurrentPath -Parent
    }
}

function Get-SafeCopyFile {
    param([string]$Path)

    Assert-SafeCopyPath $Path
    foreach ($Item in Get-ChildItem -LiteralPath $Path -Force) {
        Assert-SafeCopyPath $Item.FullName
        if ($Item.PSIsContainer) {
            Get-SafeCopyFile $Item.FullName
        }
        else {
            $Item
        }
    }
}

Assert-SafeCopyPath $SourceRoot
Assert-SafeCopyPath $TargetRoot
$ResolvedSourceRoot = (Resolve-Path -LiteralPath $SourceRoot -ErrorAction Stop).Path
$SourceSkillFile = Join-Path $ResolvedSourceRoot "SKILL.md"
$SourceFolders = @(
    "scripts"
    "references"
    "assets"
    "agents"
)

if (-not (Test-Path -LiteralPath $SourceSkillFile -PathType Leaf)) {
    throw "Skill entrypoint not found: $SourceSkillFile"
}

$SkillContent = Get-Content -LiteralPath $SourceSkillFile -Raw
$Frontmatter = [regex]::Match($SkillContent, '\A\uFEFF?---\r?\n(?<Body>[\s\S]*?)\r?\n---(?:\r?\n|\z)')
$SkillNameMatch = [regex]::Match($Frontmatter.Groups["Body"].Value,
    '(?m)^name:[ \t]*(?<Quote>[''"]?)(?<Name>[A-Za-z0-9][A-Za-z0-9._-]*)\k<Quote>[ \t]*\r?$')

if (-not $SkillNameMatch.Success) {
    throw "A valid skill name was not found in: $SourceSkillFile"
}

$SkillName = $SkillNameMatch.Groups["Name"].Value
if ($SkillName.EndsWith(".") -or $SkillName -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)') {
    throw "The skill name is not a portable directory name: $SkillName"
}
$TargetSkillRoot = Join-Path (Join-Path $TargetRoot "skills") $SkillName
Assert-SafeCopyPath $SourceSkillFile
Assert-SafeCopyPath $TargetSkillRoot
if (Test-Path -LiteralPath $TargetSkillRoot) {
    # Inspect the complete target before copying or optional cleanup.
    $null = @(Get-SafeCopyFile $TargetSkillRoot)
}
foreach ($PathPair in @(@($ResolvedSourceRoot, $TargetSkillRoot), @($TargetSkillRoot, $ResolvedSourceRoot))) {
    $Relative = [System.IO.Path]::GetRelativePath($PathPair[0], $PathPair[1])
    if ($Relative -eq "." -or (-not [System.IO.Path]::IsPathRooted($Relative) -and $Relative -notmatch '^\.\.(?:[\\/]|$)')) {
        throw "Source and target skill directories must not overlap."
    }
}
$SourceFiles = @(
    Get-Item -LiteralPath $SourceSkillFile

    foreach ($Folder in $SourceFolders) {
        $Source = Join-Path $ResolvedSourceRoot $Folder

        if (Test-Path -LiteralPath $Source -PathType Container) {
            Get-SafeCopyFile $Source
        }
    }
)
$SourceRelativePaths = @{}

if (-not $PSCmdlet.ShouldProcess($TargetSkillRoot, "Copy skill files; remove extra files: $RemoveExtraFiles")) {
    return
}

Write-Host "Copying ${SkillName} to:"
Write-Host "  $TargetSkillRoot"

foreach ($SourceFile in $SourceFiles) {
    $RelativePath = [System.IO.Path]::GetRelativePath(
        $ResolvedSourceRoot,
        $SourceFile.FullName
    )
    $SourceRelativePaths[$RelativePath] = $true
    $TargetFile = Join-Path $TargetSkillRoot $RelativePath
    $TargetDirectory = Split-Path $TargetFile -Parent

    Assert-SafeCopyPath $TargetFile
    New-Item -ItemType Directory -Path $TargetDirectory -Force -Confirm:$false | Out-Null
    Copy-Item -LiteralPath $SourceFile.FullName -Destination $TargetFile -Force -Confirm:$false
}

if ($RemoveExtraFiles) {
    Get-SafeCopyFile $TargetSkillRoot | ForEach-Object {
        $RelativePath = [System.IO.Path]::GetRelativePath(
            $TargetSkillRoot,
            $_.FullName
        )

        if (-not $SourceRelativePaths.ContainsKey($RelativePath)) {
            Remove-Item -LiteralPath $_.FullName -Force -Confirm:$false
        }
    }
}

Write-Host "Installed ${SkillName}: $TargetSkillRoot"
