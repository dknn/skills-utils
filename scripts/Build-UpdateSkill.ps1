[CmdletBinding()]
param([switch]$Check)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$Destination = Join-Path (Split-Path $PSScriptRoot -Parent) 'skills/update-dknn-skills/scripts'
foreach ($Name in @('Update-AgentSkill.ps1', 'Copy-AgentSkillToUserProfile.ps1', 'Get-AgentSkillUserProfile.ps1')) {
    $Source = Join-Path $PSScriptRoot $Name
    $Target = Join-Path $Destination $Name
    if ($Check) {
        if (-not (Test-Path -LiteralPath $Target -PathType Leaf) -or
            (Get-FileHash -LiteralPath $Source).Hash -ne (Get-FileHash -LiteralPath $Target).Hash) {
            throw "Bundled script differs: $Name. Run scripts/Build-UpdateSkill.ps1 and review the result."
        }
    }
    else { Copy-Item -LiteralPath $Source -Destination $Target -Force }
}
