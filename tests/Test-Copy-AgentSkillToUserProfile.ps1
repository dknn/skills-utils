[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path $PSScriptRoot -Parent
$ScriptUnderTest = Join-Path $RepoRoot "scripts/Copy-AgentSkillToUserProfile.ps1"
$TestDirectoryName = "skills-utils-test-$([guid]::NewGuid().ToString('N'))"
$TestRoot = Join-Path ([System.IO.Path]::GetTempPath()) $TestDirectoryName
$SourceRoot = Join-Path $TestRoot "source"
$TargetRoot = Join-Path $TestRoot "target"
$SkillName = "example-skill"
$InstalledSkillRoot = Join-Path (Join-Path $TargetRoot "skills") $SkillName

function Assert-PathExists {
    param(
        [Parameter(Mandatory)]
        [string]$LiteralPath
    )

    if (-not (Test-Path -LiteralPath $LiteralPath)) {
        throw "Expected path was not created: $LiteralPath"
    }
}

try {
    foreach ($Folder in @("scripts", "references", "assets", "agents", "other")) {
        New-Item -ItemType Directory -Path (Join-Path $SourceRoot $Folder) -Force |
            Out-Null
    }

    Set-Content -LiteralPath (Join-Path $SourceRoot "SKILL.md") -Value @"
---
name: $SkillName
description: Test fixture.
---

# Example skill
"@
    Set-Content -LiteralPath (Join-Path $SourceRoot "scripts/example.ps1") `
        -Value 'Write-Output "example"'
    Set-Content -LiteralPath (Join-Path $SourceRoot "references/example.md") `
        -Value "Example reference."
    Set-Content -LiteralPath (Join-Path $SourceRoot "assets/example.txt") `
        -Value "Example asset."
    Set-Content -LiteralPath (Join-Path $SourceRoot "agents/openai.yaml") `
        -Value "name: Example"
    Set-Content -LiteralPath (Join-Path $SourceRoot "other/not-copied.txt") `
        -Value "This folder is not part of a skill installation."

    & $ScriptUnderTest -SourceRoot $SourceRoot -TargetRoot $TargetRoot

    foreach ($RelativePath in @(
        "SKILL.md"
        "scripts/example.ps1"
        "references/example.md"
        "assets/example.txt"
        "agents/openai.yaml"
    )) {
        Assert-PathExists -LiteralPath (Join-Path $InstalledSkillRoot $RelativePath)
    }

    $UnexpectedPath = Join-Path $InstalledSkillRoot "other/not-copied.txt"
    if (Test-Path -LiteralPath $UnexpectedPath) {
        throw "Unexpected source folder was copied: $UnexpectedPath"
    }

    $StaleFile = Join-Path $InstalledSkillRoot "stale.txt"
    $OtherSkillFile = Join-Path $TargetRoot "skills/other-skill/SKILL.md"
    New-Item -ItemType File -Path $StaleFile -Force | Out-Null
    New-Item -ItemType File -Path $OtherSkillFile -Force | Out-Null

    & $ScriptUnderTest `
        -SourceRoot $SourceRoot `
        -TargetRoot $TargetRoot `
        -RemoveExtraFiles

    if (Test-Path -LiteralPath $StaleFile) {
        throw "RemoveExtraFiles did not remove: $StaleFile"
    }

    Assert-PathExists -LiteralPath $OtherSkillFile

    $PreviewRoot = Join-Path $TestRoot "preview"
    & $ScriptUnderTest -SourceRoot $SourceRoot -TargetRoot $PreviewRoot -WhatIf
    if (Test-Path -LiteralPath $PreviewRoot) { throw "WhatIf created a destination." }

    $OverlapRejected = $false
    try { & $ScriptUnderTest -SourceRoot $SourceRoot -TargetRoot $SourceRoot }
    catch { $OverlapRejected = $_.Exception.Message -match "must not overlap" }
    if (-not $OverlapRejected) { throw "Overlapping source and target must be rejected." }

    $OriginalEntryPoint = Get-Content -LiteralPath (Join-Path $SourceRoot "SKILL.md") -Raw
    Set-Content -LiteralPath (Join-Path $SourceRoot "SKILL.md") -Value "---`ndescription: Missing name.`n---`nname: fake-skill"
    $InvalidNameRejected = $false
    try { & $ScriptUnderTest -SourceRoot $SourceRoot -TargetRoot $PreviewRoot }
    catch { $InvalidNameRejected = $_.Exception.Message -match "valid skill name" }
    if (-not $InvalidNameRejected) { throw "A name outside frontmatter must not be accepted." }
    [System.IO.File]::WriteAllText((Join-Path $SourceRoot "SKILL.md"), $OriginalEntryPoint)

    $OutsideRoot = Join-Path $TestRoot "outside"
    $null = New-Item -ItemType Directory -Path $OutsideRoot
    $Sentinel = Join-Path $OutsideRoot "sentinel.txt"
    Set-Content -LiteralPath $Sentinel -Value "untouched"
    $LinkType = if ($IsWindows) { "Junction" } else { "SymbolicLink" }
    $SourceLink = Join-Path $SourceRoot "scripts/linked"
    $null = New-Item -ItemType $LinkType -Path $SourceLink -Target $OutsideRoot
    try {
        $LinkRejected = $false
        try { & $ScriptUnderTest -SourceRoot $SourceRoot -TargetRoot $PreviewRoot }
        catch { $LinkRejected = $_.Exception.Message -match "links and junctions" }
        if (-not $LinkRejected) { throw "Linked source directories must be rejected." }
    }
    finally { Remove-Item -LiteralPath $SourceLink -Force }

    $TargetLink = Join-Path $InstalledSkillRoot "linked"
    $null = New-Item -ItemType $LinkType -Path $TargetLink -Target $OutsideRoot
    try {
        $LinkRejected = $false
        try { & $ScriptUnderTest -SourceRoot $SourceRoot -TargetRoot $TargetRoot -RemoveExtraFiles }
        catch { $LinkRejected = $_.Exception.Message -match "links and junctions" }
        if (-not $LinkRejected) { throw "Linked destination directories must be rejected before cleanup." }
        if ((Get-Content -LiteralPath $Sentinel -Raw).Trim() -ne "untouched") { throw "Linked destination was modified." }
    }
    finally { Remove-Item -LiteralPath $TargetLink -Force }

    Write-Output "All Copy-AgentSkillToUserProfile tests passed."
}
finally {
    $ResolvedTempRoot = [System.IO.Path]::GetFullPath(
        [System.IO.Path]::GetTempPath()
    )
    $ResolvedTestRoot = [System.IO.Path]::GetFullPath($TestRoot)
    $ResolvedTestName = [System.IO.Path]::GetFileName($ResolvedTestRoot)

    if (
        -not $ResolvedTestRoot.StartsWith(
            $ResolvedTempRoot,
            [System.StringComparison]::OrdinalIgnoreCase
        ) -or
        -not $ResolvedTestName.StartsWith(
            "skills-utils-test-",
            [System.StringComparison]::Ordinal
        )
    ) {
        throw "Refusing to remove unexpected test path: $ResolvedTestRoot"
    }

    if (Test-Path -LiteralPath $ResolvedTestRoot) {
        Remove-Item -LiteralPath $ResolvedTestRoot -Recurse -Force
    }
}
