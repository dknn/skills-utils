[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if (-not $IsWindows) {
    throw "Windows profile discovery is only available on Windows. Use Update-AgentSkill.ps1 -TargetRoot on this platform."
}

foreach ($Profile in Get-CimInstance -ClassName Win32_UserProfile | Sort-Object SID) {
    if ($Profile.Special -or [string]::IsNullOrWhiteSpace($Profile.LocalPath) -or
        -not (Test-Path -LiteralPath $Profile.LocalPath -PathType Container)) {
        continue
    }

    $Account = $Profile.SID
    try {
        $Identity = [System.Security.Principal.SecurityIdentifier]::new($Profile.SID)
        $Account = $Identity.Translate([System.Security.Principal.NTAccount]).Value
    }
    catch [System.Security.Principal.IdentityNotMappedException] {
        # Domain accounts can be unavailable offline; the stable SID is still usable.
    }

    [pscustomobject]@{
        SID = $Profile.SID
        Account = $Account
        ProfilePath = [System.IO.Path]::GetFullPath($Profile.LocalPath)
        TargetRoot = Join-Path $Profile.LocalPath ".agents"
        Loaded = [bool]$Profile.Loaded
    }
}
