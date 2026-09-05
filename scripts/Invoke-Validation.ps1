[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path $PSScriptRoot -Parent
$ActionlintInstaller = Join-Path $PSScriptRoot "Install-Actionlint.ps1"
$RegressionTests = @(
    "Test-Copy-AgentSkillToUserProfile.ps1"
    "Test-Get-AgentSkillUserProfile.ps1"
    "Test-Update-AgentSkill.ps1"
    "Test-SkillVersion.ps1"
    "Test-UpdateSkillSnapshot.ps1"
)

& (Join-Path $PSScriptRoot 'Build-UpdateSkill.ps1') -Check

Write-Output "Installing or verifying pinned actionlint..."
$ActionlintPath = & $ActionlintInstaller

Write-Output "Linting GitHub Actions workflows..."
& $ActionlintPath -shellcheck= -pyflakes=

if ($LASTEXITCODE -ne 0) {
    throw "actionlint reported workflow errors."
}

Write-Output "Parsing PowerShell files..."
$PowerShellFiles = @(
    Get-ChildItem -LiteralPath (Join-Path $RepoRoot "scripts") -Filter "*.ps1" -File -Recurse
    Get-ChildItem -LiteralPath (Join-Path $RepoRoot "tests") -Filter "*.ps1" -File -Recurse
    Get-ChildItem -LiteralPath (Join-Path $RepoRoot "skills") -Filter "*.ps1" -File -Recurse
)
$ParserFailures = [System.Collections.Generic.List[string]]::new()

foreach ($PowerShellFile in $PowerShellFiles) {
    $Tokens = $null
    $ParseErrors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile(
        $PowerShellFile.FullName,
        [ref]$Tokens,
        [ref]$ParseErrors
    )

    foreach ($ParseError in $ParseErrors) {
        $ParserFailures.Add(
            "$($PowerShellFile.FullName):$($ParseError.Extent.StartLineNumber): $($ParseError.Message)"
        )
    }
}

if ($ParserFailures.Count -gt 0) {
    throw "PowerShell parser errors:`n$($ParserFailures -join [Environment]::NewLine)"
}

Write-Output "Running regression tests..."
foreach ($TestName in $RegressionTests) {
    # Separate processes isolate test mocks and each native exit code.
    & pwsh -NoProfile -File (Join-Path (Join-Path $RepoRoot "tests") $TestName)
    if ($LASTEXITCODE -ne 0) {
        throw "Regression tests failed: $TestName"
    }
}

Write-Output "All repository validation checks passed."
