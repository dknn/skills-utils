[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ScriptUnderTest = Join-Path (Split-Path $PSScriptRoot -Parent) "scripts/Update-AgentSkill.ps1"
$TempParent = [System.IO.Path]::GetTempPath()
$TestRoot = Join-Path $TempParent "skills-utils-update-test-$([guid]::NewGuid().ToString('N'))"
$null = New-Item -ItemType Directory -Path $TestRoot
$Fixture = @{
    Repositories = @("skills-root", "skills-nested", "skills-direct", "skills-utils")
    Commit = ('a' * 40)
    Downloads = @{}
    FailRepository = ""
    Selection = "1"
    Pages = [System.Collections.Generic.List[int]]::new()
    Padding = $false
    CorruptSize = $false
    DeclaredSize = 0
    Attributes = @{}
    Entries = @{
        "skills-root" = @{
            "snapshot/SKILL.md" = "---`nname: root-skill`ndescription: Fixture.`n---`nOriginal"
            "snapshot/scripts/never-run.ps1" = "throw 'Downloaded scripts must not execute.'"
            "snapshot/references/old.txt" = "old reference"
            "snapshot/references/empty.txt" = ""
            "snapshot/README.md" = "not installed"
        }
        "skills-nested" = @{
            "snapshot/skills/nested-skill/SKILL.md" = "---`nname: 'nested-skill'`ndescription: Fixture.`n---`nNested"
            "snapshot/tests/fixture/SKILL.md" = "---`nname: unwanted-fixture`n---"
        }
        "skills-direct" = @{
            "snapshot/direct-skill/SKILL.md" = "---`nname: direct-skill`ndescription: Fixture.`n---`nDirect"
        }
        "skills-utils" = @{ "snapshot/README.md" = "No skill here." }
    }
}

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "Assertion failed: $Message" }
}

# Network commands are replaced in the caller's scope; tests never access GitHub.
function Invoke-RestMethod {
    [CmdletBinding()]
    param([string]$Uri, [hashtable]$Headers, [int]$TimeoutSec)

    Assert-True ($TimeoutSec -gt 0) "API requests have a bounded timeout"

    if ($Uri -match '/users/example-owner/repos\?.*page=(\d+)$') {
        $Page = [int]$Matches[1]
        $Fixture.Pages.Add($Page)
        $Names = $Fixture.Repositories
        if ($Fixture.Padding -and $Page -eq 1) { $Names = @(1..100 | ForEach-Object { "other-$_" }) }
        elseif (($Fixture.Padding -and $Page -gt 2) -or (-not $Fixture.Padding -and $Page -gt 1)) { return @() }
        $Items = @(foreach ($Name in $Names) {
            [pscustomobject]@{ name = $Name; owner = @{ login = "example-owner" }; default_branch = "feature/default"; archived = $false; disabled = $false }
        })
        Write-Output -NoEnumerate $Items
        return
    }
    if ($Uri -match '/releases\?') { Write-Output -NoEnumerate @([pscustomobject]@{ draft = $false; prerelease = $false; tag_name = 'v1.0.0' }); return }
    if ($Uri -match '/repos/example-owner/[^/]+/commits/(feature%2[Ff]default|refs%2[Ff]tags%2[Ff]v1.0.0)$') {
        return [pscustomobject]@{ sha = $Fixture.Commit }
    }
    throw "Unexpected request in offline test: $Uri"
}

function Invoke-WebRequest {
    [CmdletBinding()]
    param([string]$Uri, [string]$OutFile, [int]$TimeoutSec)

    Assert-True ($TimeoutSec -gt 0) "downloads have a bounded timeout"

    Assert-True ($Uri -match '^https://codeload\.github\.com/example-owner/([^/]+)/zip/[a-f0-9]{40}$') "download must use the resolved commit"
    $Repository = $Matches[1]
    if ($Repository -eq $Fixture.FailRepository) { throw "Simulated download failure." }
    if (-not $Fixture.Downloads.ContainsKey($Repository)) { $Fixture.Downloads[$Repository] = 0 }
    $Fixture.Downloads[$Repository]++
    $Zip = [System.IO.Compression.ZipFile]::Open($OutFile, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($Name in $Fixture.Entries[$Repository].Keys) {
            $Entry = $Zip.CreateEntry($Name)
            if ($Fixture.Attributes.ContainsKey($Name)) { $Entry.ExternalAttributes = $Fixture.Attributes[$Name] }
            $Writer = [System.IO.StreamWriter]::new($Entry.Open())
            try { $Writer.Write($Fixture.Entries[$Repository][$Name]) }
            finally { $Writer.Dispose() }
        }
    }
    finally { $Zip.Dispose() }
    if ($Fixture.CorruptSize) {
        $Bytes = [System.IO.File]::ReadAllBytes($OutFile)
        for ($Index = 0; $Index -lt $Bytes.Length - 28; $Index++) {
            if ($Bytes[$Index] -eq 0x50 -and $Bytes[$Index + 1] -eq 0x4B -and
                $Bytes[$Index + 2] -eq 0x01 -and $Bytes[$Index + 3] -eq 0x02 -and
                [System.BitConverter]::ToUInt32($Bytes, $Index + 24) -gt 1) {
                # Lie about the first file's expanded size in the ZIP central directory.
                [System.Array]::Clear($Bytes, $Index + 24, 4)
                $Bytes[$Index + 24] = [byte]$Fixture.DeclaredSize
                break
            }
        }
        [System.IO.File]::WriteAllBytes($OutFile, $Bytes)
    }
}

function Read-Host {
    param([string]$Prompt)
    $Fixture.Selection
}

function Get-CimInstance {
    [CmdletBinding()]
    param([string]$ClassName)
    if ($ClassName -ne "Win32_UserProfile") { throw "Unexpected CIM class in updater test." }
    $Sid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    [pscustomobject]@{ SID = $Sid; LocalPath = $TestRoot; Special = $false; Loaded = $true }
    [pscustomobject]@{ SID = "S-1-5-18"; LocalPath = $TestRoot; Special = $true; Loaded = $true }
}

function Invoke-FixtureUpdate {
    param([hashtable]$Options)
    & $ScriptUnderTest -Owner example-owner @Options 6>$null
}

function Assert-UpdateFails {
    param([hashtable]$Options, [string]$Message)
    $Failed = $false
    try { $null = Invoke-FixtureUpdate $Options }
    catch { $Failed = $true }
    Assert-True $Failed $Message
}

try {
    $FirstTarget = Join-Path $TestRoot "first-user/.agents"
    $SecondTarget = Join-Path $TestRoot "second-user/.agents"
    $PreviewTarget = Join-Path $TestRoot "preview-only"

    $Rows = @(Invoke-FixtureUpdate @{ TargetRoot = @($PreviewTarget); WhatIf = $true })
    Assert-True ($Rows.Count -eq 3 -and @($Rows | Where-Object Status -ne "WhatIf").Count -eq 0) "WhatIf reports every skill"
    Assert-True (-not (Test-Path -LiteralPath $PreviewTarget)) "WhatIf must not create a target or receipt"
    $Rows = @(Invoke-FixtureUpdate @{ TargetRoot = @($PreviewTarget); List = $true })
    Assert-True ($Rows.Count -eq 3 -and -not (Test-Path -LiteralPath $PreviewTarget)) "List does not install"

    $Fixture.Downloads.Clear()
    $Rows = @(Invoke-FixtureUpdate @{ TargetRoot = @($FirstTarget, $SecondTarget) })
    Assert-True ($Rows.Count -eq 6 -and @($Rows | Where-Object Status -ne "Installed").Count -eq 0) "install all three layouts for two targets"
    foreach ($Repository in $Fixture.Repositories) {
        Assert-True ($Fixture.Downloads[$Repository] -eq 1) "download each repository once for multiple targets"
    }
    foreach ($Root in @($FirstTarget, $SecondTarget)) {
        foreach ($File in Get-ChildItem -LiteralPath (Join-Path $Root 'skills') -Filter '.skills-utils-install.json' -Recurse -Force) {
            $R = Get-Content -LiteralPath $File.FullName -Raw | ConvertFrom-Json -AsHashtable
            $R.Selection = 'Latest'; $R.Tag = $null
            $R | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $File.FullName
        }
    }
    $InstalledRoot = Join-Path $FirstTarget "skills/root-skill"
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $InstalledRoot "README.md"))) "exclude repository files"
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $FirstTarget "skills/unwanted-fixture"))) "ignore nested test fixtures"
    $ReceiptPath = Join-Path $InstalledRoot ".skills-utils-install.json"
    $Receipt = Get-Content -LiteralPath $ReceiptPath -Raw | ConvertFrom-Json
    Assert-True ($Receipt.Commit -eq $Fixture.Commit -and $Receipt.Repository -eq "example-owner/skills-root") "record exact provenance"
    $OriginalReceipt = Get-Content -LiteralPath $ReceiptPath -Raw
    $Rows = @(Invoke-FixtureUpdate @{ TargetRoot = @($FirstTarget) })
    Assert-True (@($Rows | Where-Object Status -ne "Unchanged").Count -eq 0) "unchanged versions are not reinstalled"
    Assert-True ((Get-Content -LiteralPath $ReceiptPath -Raw) -ceq $OriginalReceipt) "unchanged receipt stays intact"

    $LegacyTarget = Join-Path $TestRoot "legacy"
    $LegacySkill = Join-Path $LegacyTarget "skills/root-skill"
    $null = New-Item -ItemType Directory -Path (Split-Path $LegacySkill -Parent) -Force
    Copy-Item -LiteralPath $InstalledRoot -Destination $LegacySkill -Recurse
    Remove-Item -LiteralPath (Join-Path $LegacySkill ".skills-utils-install.json") -Force
    $Rows = @(Invoke-FixtureUpdate @{ TargetRoot = @($LegacyTarget); SkillName = @("root-skill") })
    Assert-True ($Rows[0].Status -eq "Adopted") "adopt matching legacy installation"
    Remove-Item -LiteralPath (Join-Path $LegacySkill ".skills-utils-install.json") -Force
    Set-Content -LiteralPath (Join-Path $LegacySkill "SKILL.md") -Value "legacy modification"
    Assert-UpdateFails @{ TargetRoot = @($LegacyTarget); SkillName = @("root-skill") } "reject differing legacy installation"

    $ExtraFile = Join-Path $InstalledRoot "personal.txt"
    Set-Content -LiteralPath $ExtraFile -Value "keep me"
    $Fixture.Commit = 'b' * 40
    $Fixture.Entries["skills-root"]["snapshot/SKILL.md"] = "---`nname: root-skill`ndescription: Fixture.`n---`nUpdated"
    $Fixture.Entries["skills-root"].Remove("snapshot/references/old.txt")
    $Rows = @(Invoke-FixtureUpdate @{ TargetRoot = @($FirstTarget); SkillName = @("root-skill") })
    Assert-True ($Rows.Count -eq 1 -and $Rows[0].Status -eq "Updated") "update the selected skill"
    Assert-True ((Get-Content -LiteralPath (Join-Path $InstalledRoot "SKILL.md") -Raw) -match 'Updated') "new content installed"
    Assert-True (Test-Path -LiteralPath $ExtraFile) "preserve extra files by default"
    Assert-True (Test-Path -LiteralPath (Join-Path $InstalledRoot "references/old.txt")) "preserve upstream-removed files by default"
    $SecondReceipt = Get-Content -LiteralPath (Join-Path $SecondTarget "skills/root-skill/.skills-utils-install.json") -Raw | ConvertFrom-Json
    Assert-True ($SecondReceipt.Commit -eq ('a' * 40)) "unselected target is unchanged"

    $Rows = @(Invoke-FixtureUpdate @{ TargetRoot = @($FirstTarget); SkillName = @("root-skill"); RemoveExtraFiles = $true })
    Assert-True (-not (Test-Path -LiteralPath $ExtraFile)) "explicit cleanup removes extras"
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $InstalledRoot "references/old.txt"))) "explicit cleanup removes stale files"
    Assert-True (Test-Path -LiteralPath (Join-Path $FirstTarget "skills/nested-skill/SKILL.md")) "cleanup preserves sibling skills"

    $EntryPoint = Join-Path $InstalledRoot "SKILL.md"
    $CleanContent = Get-Content -LiteralPath $EntryPoint -Raw
    Set-Content -LiteralPath $EntryPoint -Value "local edits"
    Assert-UpdateFails @{ TargetRoot = @($FirstTarget); SkillName = @("root-skill") } "local modifications must conflict"
    Assert-True ((Get-Content -LiteralPath $EntryPoint -Raw) -match 'local edits') "do not overwrite local modifications"
    [System.IO.File]::WriteAllText($EntryPoint, $CleanContent)

    $Fixture.FailRepository = "skills-root"
    Assert-UpdateFails @{ TargetRoot = @($FirstTarget) } "download failure must report failure"
    Assert-True ((Get-Content -LiteralPath $EntryPoint -Raw) -ceq $CleanContent) "failed download preserves installation"
    $Fixture.FailRepository = ""

    $Fixture.Repositories = @("skills-root")
    $Fixture.Padding = $true
    $Fixture.Pages.Clear()
    $null = Invoke-FixtureUpdate @{ TargetRoot = @($FirstTarget); List = $true }
    Assert-True ($Fixture.Pages.Count -eq 2 -and $Fixture.Pages[1] -eq 2) "enumerate later repository pages"
    $Fixture.Padding = $false

    $ConflictTarget = Join-Path $TestRoot "collision"
    $Fixture.Repositories = @("skills-root", "skills-direct")
    $Fixture.Entries["skills-direct"]["snapshot/direct-skill/SKILL.md"] = "---`nname: ROOT-SKILL`n---`nCollision"
    Assert-UpdateFails @{ TargetRoot = @($ConflictTarget) } "case-insensitive source name collision"
    Assert-True (-not (Test-Path -LiteralPath $ConflictTarget)) "collision must not install either source"

    $Fixture.Repositories = @("skills-root")
    $BadTarget = Join-Path $TestRoot "bad-archive"
    foreach ($UnsafeName in @("../escape.txt", "snapshot/../../escape.txt", "snapshot/C:/escape.txt", "snapshot/CON.txt", 'snapshot\escape.txt')) {
        $Fixture.Entries["skills-root"][$UnsafeName] = "unsafe"
        Assert-UpdateFails @{ TargetRoot = @($BadTarget) } "reject unsafe archive path $UnsafeName"
        Assert-True (-not (Test-Path -LiteralPath $BadTarget)) "unsafe archive cannot create target"
        $Fixture.Entries["skills-root"].Remove($UnsafeName)
    }
    $Fixture.Attributes["snapshot/scripts/never-run.ps1"] = -1610612736
    Assert-UpdateFails @{ TargetRoot = @($BadTarget) } "reject archive symbolic links"
    $Fixture.Attributes.Clear()
    $Fixture.CorruptSize = $true
    foreach ($DeclaredSize in @(0, 1)) {
        $Fixture.DeclaredSize = $DeclaredSize
        Assert-UpdateFails @{ TargetRoot = @($BadTarget) } "reject an archive that understates its expanded data size as $DeclaredSize"
        Assert-True (-not (Test-Path -LiteralPath $BadTarget)) "malformed archive cannot create target"
    }
    $Fixture.CorruptSize = $false

    $Fixture.Selection = "99"
    Assert-UpdateFails @{ TargetRoot = @($BadTarget); Interactive = $true } "invalid menu choice cancels"
    Assert-True (-not (Test-Path -LiteralPath $BadTarget)) "invalid choice cannot create target"
    $Fixture.Selection = "1"
    $Rows = @(Invoke-FixtureUpdate @{ TargetRoot = @($FirstTarget); Interactive = $true; List = $true })
    Assert-True ($Rows.Count -eq 1) "numbered skill selection"

    $Fixture.Commit = 'c' * 40
    $LockPath = Join-Path $FirstTarget ".skills-utils.lock"
    $Lock = [System.IO.File]::Open($LockPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
    try { Assert-UpdateFails @{ TargetRoot = @($FirstTarget) } "concurrent update must fail safely" }
    finally { $Lock.Dispose() }
    Assert-True ((Get-Content -LiteralPath $EntryPoint -Raw) -ceq $CleanContent) "locked installation stays unchanged"

    # Inject a failed directory swap and verify automatic restoration.
    function Move-Item {
        [CmdletBinding(SupportsShouldProcess)]
        param([string]$LiteralPath, [string]$Destination)
        if ($LiteralPath -match '[\\/]skills-utils-stage-[^\\/]+[\\/]skills[\\/]root-skill$') {
            throw "Simulated destination swap failure."
        }
        Microsoft.PowerShell.Management\Move-Item -LiteralPath $LiteralPath -Destination $Destination
    }
    try {
        Assert-UpdateFails @{ TargetRoot = @($FirstTarget) } "failed swap reports failure"
        Assert-True ((Get-Content -LiteralPath $EntryPoint -Raw) -ceq $CleanContent) "failed swap restores previous content"
        $RestoredReceipt = Get-Content -LiteralPath $ReceiptPath -Raw | ConvertFrom-Json
        Assert-True ($RestoredReceipt.Commit -eq ('b' * 40)) "failed swap restores previous receipt"
    }
    finally { Remove-Item -LiteralPath Function:\Move-Item }

    $ConcurrentFile = Join-Path $InstalledRoot "concurrent.txt"
    Set-Content -LiteralPath $ConcurrentFile -Value "before"
    function Copy-Item {
        [CmdletBinding(SupportsShouldProcess)]
        param([string]$LiteralPath, [string]$Destination, [switch]$Force)
        Microsoft.PowerShell.Management\Copy-Item -LiteralPath $LiteralPath -Destination $Destination -Force:$Force
        if ($Destination -match '[\\/]skills-utils-stage-[^\\/]+[\\/]skills[\\/]root-skill[\\/]concurrent.txt$') {
            [System.IO.File]::WriteAllText($ConcurrentFile, "edited during update")
        }
    }
    try {
        Assert-UpdateFails @{ TargetRoot = @($FirstTarget) } "concurrent external edits must stop replacement"
        Assert-True ((Get-Content -LiteralPath $ConcurrentFile -Raw) -eq "edited during update") "preserve external edits made during preparation"
        Assert-True ((Get-Content -LiteralPath $EntryPoint -Raw) -ceq $CleanContent) "concurrent edits leave the old skill installed"
    }
    finally { Remove-Item -LiteralPath Function:\Copy-Item }

    # Tampered receipt paths cannot escape the selected skill.
    $OriginalReceipt = Get-Content -LiteralPath $ReceiptPath -Raw
    $Receipt = $OriginalReceipt | ConvertFrom-Json -AsHashtable
    $Receipt.Files["../escape.txt"] = 'a' * 64
    $Receipt | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $ReceiptPath
    Assert-UpdateFails @{ TargetRoot = @($FirstTarget) } "reject path traversal in receipts"
    [System.IO.File]::WriteAllText($ReceiptPath, $OriginalReceipt)

    if ($IsWindows) {
        $Sid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        $Rows = @(Invoke-FixtureUpdate @{ UserSid = @($Sid); ProfileDirectory = ".codex"; WhatIf = $true })
        Assert-True ($Rows.Count -eq 1 -and $Rows[0].Target -eq (Join-Path $TestRoot ".codex/skills/root-skill")) "SID selection resolves the fixture profile and alternate agent directory"
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $TestRoot ".codex"))) "profile preview does not install"
        $Rows = @(Invoke-FixtureUpdate @{ SelectUser = $true; List = $true })
        Assert-True ($Rows.Count -eq 1 -and $Rows[0].Target -eq (Join-Path $TestRoot ".agents/skills/root-skill")) "numbered profile selection resolves its destination"
        Assert-UpdateFails @{ UserSid = @("S-1-5-21-1-2-3-9999"); List = $true } "unknown SID must not select another user"
    }

    Write-Output "All Update-AgentSkill tests passed."
}
finally {
    $ResolvedRoot = [System.IO.Path]::GetFullPath($TestRoot)
    if ((Split-Path $ResolvedRoot -Parent) -ne [System.IO.Path]::GetFullPath($TempParent).TrimEnd([System.IO.Path]::DirectorySeparatorChar) -or
        -not (Split-Path $ResolvedRoot -Leaf).StartsWith("skills-utils-update-test-", [System.StringComparison]::Ordinal)) {
        throw "Refusing to clean an unexpected test directory: $ResolvedRoot"
    }
    Remove-Item -LiteralPath $ResolvedRoot -Recurse -Force
}
