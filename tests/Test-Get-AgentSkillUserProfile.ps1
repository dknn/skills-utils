[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ScriptUnderTest = Join-Path (Split-Path $PSScriptRoot -Parent) "scripts/Get-AgentSkillUserProfile.ps1"

if (-not $IsWindows) {
    $Failed = $false
    try { & $ScriptUnderTest }
    catch { $Failed = $_.Exception.Message -match "only available on Windows" }
    if (-not $Failed) { throw "Profile discovery must explain its Windows-only requirement." }
    Write-Output "Non-Windows profile discovery test passed."
    return
}

$TempParent = [System.IO.Path]::GetTempPath()
$TestRoot = Join-Path $TempParent "skills-utils-profile-test-$([guid]::NewGuid().ToString('N'))"
$null = New-Item -ItemType Directory -Path $TestRoot
$AccountSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value

function Get-CimInstance {
    [CmdletBinding()]
    param([string]$ClassName)

    if ($ClassName -ne "Win32_UserProfile") { throw "Unexpected CIM class in test." }
    [pscustomobject]@{ SID = $AccountSid; LocalPath = $TestRoot; Special = $false; Loaded = $true }
    [pscustomobject]@{ SID = "S-1-5-18"; LocalPath = $TestRoot; Special = $true; Loaded = $true }
    [pscustomobject]@{ SID = "S-1-5-19"; LocalPath = (Join-Path $TestRoot "missing"); Special = $false; Loaded = $false }
    [pscustomobject]@{ SID = "S-1-5-20"; LocalPath = ""; Special = $false; Loaded = $false }
}

try {
    $Profiles = @(& $ScriptUnderTest)
    if ($Profiles.Count -ne 1 -or $Profiles[0].SID -ne $AccountSid -or
        $Profiles[0].ProfilePath -ne $TestRoot -or -not $Profiles[0].Loaded -or
        $Profiles[0].TargetRoot -ne (Join-Path $TestRoot ".agents")) {
        throw "Expected only the existing non-system fixture profile with its SID and destination."
    }
    Write-Output "All Get-AgentSkillUserProfile tests passed."
}
finally {
    $ResolvedRoot = [System.IO.Path]::GetFullPath($TestRoot)
    if ((Split-Path $ResolvedRoot -Parent) -ne [System.IO.Path]::GetFullPath($TempParent).TrimEnd([System.IO.Path]::DirectorySeparatorChar) -or
        -not (Split-Path $ResolvedRoot -Leaf).StartsWith("skills-utils-profile-test-", [System.StringComparison]::Ordinal)) {
        throw "Refusing to clean an unexpected test directory: $ResolvedRoot"
    }
    Remove-Item -LiteralPath $ResolvedRoot -Recurse -Force
}
