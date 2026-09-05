[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Current')]
param(
    [string]$RepositoryPattern = 'skills-*',
    [string[]]$SkillName,
    [ValidateSet('Stable', 'Latest')][string]$Channel,
    [string]$ExactVersion,
    [switch]$AllowMajorUpgrade,
    [switch]$AllowDowngrade,
    [Parameter(ParameterSetName = 'Current')][string[]]$TargetRoot,
    [Parameter(ParameterSetName = 'Current')][string[]]$SearchRoot,
    [Parameter(Mandatory, ParameterSetName = 'Profiles')][string[]]$UserSid,
    [Parameter(Mandatory, ParameterSetName = 'SelectProfiles')][switch]$SelectUser,
    [Parameter(ParameterSetName = 'Profiles')]
    [Parameter(ParameterSetName = 'SelectProfiles')]
    [ValidateSet('.agents', '.codex')][string]$ProfileDirectory = '.agents',
    [switch]$Interactive,
    [switch]$List,
    [switch]$RemoveExtraFiles
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$Options = @{} + $PSBoundParameters
if ($PSCmdlet.ParameterSetName -eq 'Current' -and -not $TargetRoot) {
    $CodexRoot = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $HOME '.codex' }
    $Options.TargetRoot = @($CodexRoot)
    if (-not $SearchRoot) { $Options.SearchRoot = @((Join-Path $HOME '.agents'), $CodexRoot) }
}
$Options.Owner = 'dknn'
$TempParent = [System.IO.Path]::GetTempPath()
$Snapshot = Join-Path $TempParent "skills-utils-run-$([guid]::NewGuid().ToString('N'))"
$null = [System.IO.Directory]::CreateDirectory($Snapshot)
try {
    foreach ($Name in @('Update-AgentSkill.ps1', 'Copy-AgentSkillToUserProfile.ps1', 'Get-AgentSkillUserProfile.ps1')) {
        $Source = Join-Path $PSScriptRoot $Name
        $Ancestor = [System.IO.Path]::GetFullPath($Source)
        while ($Ancestor) {
            if ((Get-Item -LiteralPath $Ancestor -Force).Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
                throw "Linked updater scripts are not supported: $Ancestor"
            }
            $Ancestor = Split-Path $Ancestor -Parent
        }
        Copy-Item -LiteralPath $Source -Destination (Join-Path $Snapshot $Name) -WhatIf:$false -Confirm:$false
    }
    & (Join-Path $Snapshot 'Update-AgentSkill.ps1') @Options
}
finally {
    $Resolved = [System.IO.Path]::GetFullPath($Snapshot)
    if ((Split-Path $Resolved -Parent) -ne [System.IO.Path]::GetFullPath($TempParent).TrimEnd([System.IO.Path]::DirectorySeparatorChar) -or
        -not (Split-Path $Resolved -Leaf).StartsWith('skills-utils-run-', [System.StringComparison]::Ordinal)) {
        throw "Unexpected snapshot cleanup target: $Resolved"
    }
    if ((Get-Item -LiteralPath $Resolved -Force).Attributes -band [System.IO.FileAttributes]::ReparsePoint -or
        @(Get-ChildItem -LiteralPath $Resolved -Force | Where-Object { $_.PSIsContainer -or ($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) }).Count) {
        throw "Unexpected snapshot content; retained at $Resolved"
    }
    Remove-Item -LiteralPath $Resolved -Recurse -Force -WhatIf:$false -Confirm:$false
}
