[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$SourceRoot,

    [string]$TargetRoot = (Join-Path $HOME ".agents"),

    [switch]$RemoveExtraFiles
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

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
$SkillNameMatch = [regex]::Match(
    $SkillContent,
    '(?m)^name:\s*(?<Name>[A-Za-z0-9][A-Za-z0-9._-]*)\s*$'
)

if (-not $SkillNameMatch.Success) {
    throw "A valid skill name was not found in: $SourceSkillFile"
}

$SkillName = $SkillNameMatch.Groups["Name"].Value
$TargetSkillRoot = Join-Path (Join-Path $TargetRoot "skills") $SkillName
$SourceFiles = @(
    Get-Item -LiteralPath $SourceSkillFile

    foreach ($Folder in $SourceFolders) {
        $Source = Join-Path $ResolvedSourceRoot $Folder

        if (Test-Path -LiteralPath $Source -PathType Container) {
            Get-ChildItem -LiteralPath $Source -Recurse -File
        }
    }
)
$SourceRelativePaths = @{}

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

    New-Item -ItemType Directory -Path $TargetDirectory -Force | Out-Null
    Copy-Item -LiteralPath $SourceFile.FullName -Destination $TargetFile -Force
}

if ($RemoveExtraFiles) {
    Get-ChildItem -LiteralPath $TargetSkillRoot -Recurse -File | ForEach-Object {
        $RelativePath = [System.IO.Path]::GetRelativePath(
            $TargetSkillRoot,
            $_.FullName
        )

        if (-not $SourceRelativePaths.ContainsKey($RelativePath)) {
            Remove-Item -LiteralPath $_.FullName -Force
        }
    }
}

Write-Host "Installed ${SkillName}: $TargetSkillRoot"
