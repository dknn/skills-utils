[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$Updater = Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts/Update-AgentSkill.ps1'
$TempParent = [System.IO.Path]::GetTempPath()
$TestRoot = Join-Path $TempParent "skills-utils-version-test-$([guid]::NewGuid().ToString('N'))"
$null = [System.IO.Directory]::CreateDirectory($TestRoot)
$Fixture = @{
    Tags = @('v1.0.0'); Sha = @{ 'v1.0.0' = ('a' * 40); 'v1.2.0' = ('b' * 40); 'v1.10.0' = ('c' * 40); 'v2.0.0' = ('d' * 40) }
    Branch = ('f' * 40); Paged = $false; Pages = [System.Collections.Generic.List[int]]::new(); Downloads = @{}
}
function Assert-True { param([bool]$Value, [string]$Message) if (-not $Value) { throw "Assertion failed: $Message" } }
function Invoke-RestMethod {
    [CmdletBinding()]param([string]$Uri, [hashtable]$Headers, [int]$TimeoutSec)
    if ($Uri -match '/users/example/repos\?') { return @{name='skills-demo';owner=@{login='example'};default_branch='main';archived=$false;disabled=$false} }
    if ($Uri -match '/releases\?.*page=(\d+)$') {
        $Page = [int]$Matches[1]; $Fixture.Pages.Add($Page)
        if ($Fixture.Paged -and $Page -eq 1) { return @(1..100 | ForEach-Object { @{draft=$false;prerelease=$true;tag_name="v9.0.0-rc$_"} }) }
        if (($Fixture.Paged -and $Page -gt 2) -or (-not $Fixture.Paged -and $Page -gt 1)) { return @() }
        return @($Fixture.Tags | ForEach-Object { @{draft=$false;prerelease=$false;tag_name=$_} })
    }
    if ($Uri -match '/commits/main$') { return @{sha=$Fixture.Branch} }
    if ($Uri -match '/commits/refs%2[Ff]tags%2[Ff](v[0-9.]+)$') { return @{sha=$Fixture.Sha[$Matches[1]]} }
    throw "Unexpected offline API request: $Uri"
}
function Invoke-WebRequest {
    [CmdletBinding()]param([string]$Uri, [string]$OutFile, [int]$TimeoutSec)
    if ($Uri -notmatch '/zip/([a-f0-9]{40})$') { throw "Unexpected download: $Uri" }
    $Sha = $Matches[1]
    if (-not $Fixture.Downloads.ContainsKey($Sha)) { $Fixture.Downloads[$Sha] = 0 }
    $Fixture.Downloads[$Sha]++
    $Zip = [System.IO.Compression.ZipFile]::Open($OutFile, 'Create')
    try {
        $Writer = [System.IO.StreamWriter]::new($Zip.CreateEntry('source/SKILL.md').Open())
        try { $Writer.Write("---`nname: demo`ndescription: Offline fixture.`n---`n$Sha") } finally { $Writer.Dispose() }
    } finally { $Zip.Dispose() }
}
function Update-Fixture { param([hashtable]$Options) & $Updater -Owner example @Options 6>$null }
function Read-Receipt { param([string]$Root) Get-Content -LiteralPath (Join-Path $Root 'skills/demo/.skills-utils-install.json') -Raw | ConvertFrom-Json -AsHashtable }
function Assert-Fails {
    param([hashtable]$Options, [string]$Message)
    $Failed=$false
    try { $null = Update-Fixture $Options } catch { $Failed=$true }
    Assert-True $Failed $Message
}
try {
    $A=Join-Path $TestRoot 'a'; $B=Join-Path $TestRoot 'b'
    $null=Update-Fixture @{TargetRoot=@($A)}
    Assert-True ((Read-Receipt $A).Tag -eq 'v1.0.0') 'new installs use Stable'
    $Fixture.Paged=$true; $Fixture.Tags=@('v1.2.0','v1.10.0','v1.0.0'); $Fixture.Pages.Clear()
    $null=Update-Fixture @{TargetRoot=@($A)}
    Assert-True ((Read-Receipt $A).Tag -eq 'v1.10.0' -and 2 -in $Fixture.Pages) 'numeric SemVer ordering and release pagination'
    $Fixture.Paged=$false
    Assert-Fails @{TargetRoot=@($A);RepositoryPattern='skills-demo';ExactVersion='v1.0.0'} 'downgrade requires explicit opt-in'
    $null=Update-Fixture @{TargetRoot=@($A);RepositoryPattern='skills-demo';ExactVersion='v1.0.0';AllowDowngrade=$true}
    $null=Update-Fixture @{TargetRoot=@($A)}
    Assert-True ((Read-Receipt $A).Selection -eq 'Pinned' -and (Read-Receipt $A).Tag -eq 'v1.0.0') 'normal update preserves pin'
    $Fixture.Sha['v1.10.0']='e'*40
    Assert-Fails @{TargetRoot=@($A);RepositoryPattern='skills-demo';Channel='Stable'} 'detect moved previously observed tag'
    $Fixture.Sha['v1.10.0']='c'*40
    $Fixture.Tags=@('v1.0.0')
    $Rows=@(Update-Fixture @{TargetRoot=@($A);RepositoryPattern='skills-demo';Channel='Stable'})
    Assert-True ($Rows[0].Status -eq 'Updated' -and (Read-Receipt $A).Selection -eq 'Stable') 'same SHA permits metadata-only source change'
    $Fixture.Tags=@('v1.0.0','v2.0.0')
    Assert-Fails @{TargetRoot=@($A)} 'major version boundary requires opt-in'
    $null=Update-Fixture @{TargetRoot=@($A);RepositoryPattern='skills-demo';AllowMajorUpgrade=$true}
    Assert-True ((Read-Receipt $A).Tag -eq 'v2.0.0') 'explicit major upgrade works'
    $Fixture.Tags=@()
    Assert-Fails @{TargetRoot=@($B)} 'missing stable release does not fall back'
    Assert-True (-not (Test-Path -LiteralPath $B)) 'no release creates no target'
    Assert-Fails @{TargetRoot=@($B);Channel='Latest'} 'source changes require explicit repository'
    $null=Update-Fixture @{TargetRoot=@($B);RepositoryPattern='skills-demo';Channel='Latest'}
    $Receipt=Read-Receipt $B; $Receipt.Version=1; $Receipt.Remove('Selection'); $Receipt.Remove('Tag')
    $Receipt | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $B 'skills/demo/.skills-utils-install.json')
    # Existing Latest installations keep working without a Stable release.
    $null=Update-Fixture @{TargetRoot=@($B)}
    Assert-True ((Read-Receipt $B).Version -eq 2 -and (Read-Receipt $B).Selection -eq 'Latest') 'receipt 1 migrates to Latest'
    $Fixture.Tags=@('v2.0.0'); $Fixture.Downloads.Clear()
    $null=Update-Fixture @{TargetRoot=@($A,$B)}
    Assert-True ((Read-Receipt $A).Tag -eq 'v2.0.0' -and (Read-Receipt $B).Commit -eq $Fixture.Branch) 'different target source choices persist'
    Assert-True ($Fixture.Downloads[('d'*40)] -eq 1 -and $Fixture.Downloads[$Fixture.Branch] -eq 1) 'download once per repository SHA'
    $NewRoot=Join-Path $TestRoot 'new-root'
    $Rows=@(Update-Fixture @{TargetRoot=@($NewRoot);SearchRoot=@($A)})
    Assert-True ($Rows[0].Target -eq (Join-Path $A 'skills/demo') -and -not (Test-Path -LiteralPath $NewRoot)) 'discover existing root without creating duplicate'
    Assert-Fails @{TargetRoot=@($A);SearchRoot=@($B)} 'ambiguous installations fail'
    Assert-Fails @{TargetRoot=@($A);RepositoryPattern='skills-demo';ExactVersion='v3.0.0'} 'unknown version fails'
    Write-Output 'All skill version tests passed.'
}
finally {
    $Resolved=[System.IO.Path]::GetFullPath($TestRoot)
    if ((Split-Path $Resolved -Parent) -ne [System.IO.Path]::GetFullPath($TempParent).TrimEnd([System.IO.Path]::DirectorySeparatorChar) -or
        -not (Split-Path $Resolved -Leaf).StartsWith('skills-utils-version-test-', [System.StringComparison]::Ordinal)) { throw 'Unsafe test cleanup path.' }
    Remove-Item -LiteralPath $Resolved -Recurse -Force
}
