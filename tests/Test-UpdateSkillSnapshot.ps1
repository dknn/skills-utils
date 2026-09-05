[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$TempParent = [System.IO.Path]::GetTempPath()
$TestRoot = Join-Path $TempParent "skills-utils-snapshot-test-$([guid]::NewGuid().ToString('N'))"
$null = [System.IO.Directory]::CreateDirectory($TestRoot)
try {
    $Wrapper = Join-Path (Split-Path $PSScriptRoot -Parent) 'skills/update-dknn-skills/scripts/Update-DknnSkill.ps1'
    Copy-Item -LiteralPath $Wrapper -Destination (Join-Path $TestRoot 'Update-DknnSkill.ps1')
    # Reject explicit empty roots before touching any profile or starting the engine.
    foreach ($Options in @(@{TargetRoot=@('')}, @{TargetRoot=@($TestRoot); SearchRoot=@('')})) {
        $Rejected = $false
        try { & (Join-Path $TestRoot 'Update-DknnSkill.ps1') @Options }
        catch { $Rejected = $_.FullyQualifiedErrorId -match 'ParameterArgumentValidationError' }
        if (-not $Rejected) { throw 'Explicit empty roots must fail parameter validation.' }
    }
    Set-Content -LiteralPath (Join-Path $TestRoot 'Copy-AgentSkillToUserProfile.ps1') -Value "'original helper'"
    Set-Content -LiteralPath (Join-Path $TestRoot 'Get-AgentSkillUserProfile.ps1') -Value "'profile helper'"
    @'
[CmdletBinding(SupportsShouldProcess)]
param($Owner, $TargetRoot, $SearchRoot)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# Simulate replacement of the installed helper while this updater is running.
Set-Content -LiteralPath (Join-Path $TargetRoot[0] 'Copy-AgentSkillToUserProfile.ps1') -Value "throw 'replacement must not execute during this run'" -WhatIf:$false
[pscustomobject]@{
    Owner = $Owner
    Helper = & (Join-Path $PSScriptRoot 'Copy-AgentSkillToUserProfile.ps1')
    RunRoot = $PSScriptRoot
    Target = $TargetRoot[0]
    SearchCount = @($SearchRoot | Where-Object { $_ }).Count
}
'@ | Set-Content -LiteralPath (Join-Path $TestRoot 'Update-AgentSkill.ps1')
    $Result = & (Join-Path $TestRoot 'Update-DknnSkill.ps1') -TargetRoot @($TestRoot) -WhatIf
    if ($Result.Owner -ne 'dknn' -or $Result.Helper -ne 'original helper' -or $Result.Target -ne $TestRoot -or $Result.SearchCount -ne 0) {
        throw 'Snapshot must retain old helpers, select dknn, and honor an explicit target without discovery.'
    }
    if ($Result.RunRoot -eq $TestRoot -or (Test-Path -LiteralPath $Result.RunRoot)) { throw 'Snapshot must run separately and be cleaned afterward.' }
    # Failure also cleans its snapshot and is propagated.
    Set-Content -LiteralPath (Join-Path $TestRoot 'Update-AgentSkill.ps1') -Value "throw 'simulated updater failure'"
    $Before = @(Get-ChildItem -LiteralPath $TempParent -Directory -Filter 'skills-utils-run-*' | ForEach-Object FullName)
    $Failed = $false
    try { & (Join-Path $TestRoot 'Update-DknnSkill.ps1') -TargetRoot @($TestRoot) } catch { $Failed = $_.Exception.Message -match 'simulated updater failure' }
    $After = @(Get-ChildItem -LiteralPath $TempParent -Directory -Filter 'skills-utils-run-*' | Where-Object { $_.FullName -notin $Before })
    if (-not $Failed -or $After.Count) { throw 'Updater failures must propagate and clean the snapshot.' }
    Write-Output 'Updater snapshot tests passed.'
}
finally {
    $Resolved = [System.IO.Path]::GetFullPath($TestRoot)
    if ((Split-Path $Resolved -Parent) -ne [System.IO.Path]::GetFullPath($TempParent).TrimEnd([System.IO.Path]::DirectorySeparatorChar) -or
        -not (Split-Path $Resolved -Leaf).StartsWith('skills-utils-snapshot-test-', [System.StringComparison]::Ordinal)) { throw 'Unsafe test cleanup path.' }
    Remove-Item -LiteralPath $Resolved -Recurse -Force
}
