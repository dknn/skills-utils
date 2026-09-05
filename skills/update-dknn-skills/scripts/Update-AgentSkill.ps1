[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = "Current")]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9-]{0,38}$')]
    [string]$Owner,

    [ValidateNotNullOrEmpty()]
    [string]$RepositoryPattern = "skills-*",

    [string[]]$SkillName,

    [ValidateSet("Stable", "Latest")]
    [string]$Channel,
    [ValidatePattern('^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$')]
    [string]$ExactVersion,
    [switch]$AllowMajorUpgrade,
    [switch]$AllowDowngrade,
    [Parameter(ParameterSetName = "Current")]
    [string[]]$SearchRoot,

    [Parameter(ParameterSetName = "Current")]
    [ValidateNotNullOrEmpty()]
    [string[]]$TargetRoot = @((Join-Path $HOME ".agents")),

    [Parameter(Mandatory, ParameterSetName = "Profiles")]
    [ValidateNotNullOrEmpty()]
    [string[]]$UserSid,

    [Parameter(Mandatory, ParameterSetName = "SelectProfiles")]
    [switch]$SelectUser,

    [Parameter(ParameterSetName = "Profiles")]
    [Parameter(ParameterSetName = "SelectProfiles")]
    [ValidateSet(".agents", ".codex")]
    [string]$ProfileDirectory = ".agents",

    [switch]$Interactive,
    [switch]$List,
    [switch]$RemoveExtraFiles
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ReceiptName = ".skills-utils-install.json"
if (($Channel -or $ExactVersion -or $AllowMajorUpgrade -or $AllowDowngrade) -and
    $RepositoryPattern -notmatch '^[A-Za-z0-9._-]+$') {
    throw "Select one explicit repository with -RepositoryPattern when changing source selection or version boundaries."
}
if ($Channel -and $ExactVersion) { throw "Choose either -Channel or -ExactVersion." }
if ($SearchRoot -and $TargetRoot.Count -ne 1) { throw "Root discovery requires one default TargetRoot." }
$CopyScript = Join-Path $PSScriptRoot "Copy-AgentSkillToUserProfile.ps1"

function Assert-UpdatePath {
    param([string]$Path)

    $CurrentPath = [System.IO.Path]::GetFullPath($Path)
    while ($CurrentPath) {
        $Item = Get-Item -LiteralPath $CurrentPath -Force -ErrorAction SilentlyContinue
        if ($null -ne $Item -and ($Item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
            throw "Symbolic links and junctions are not supported: $CurrentPath"
        }
        $CurrentPath = Split-Path $CurrentPath -Parent
    }
}

function Get-UpdateFile {
    param([string]$Path)

    Assert-UpdatePath $Path
    foreach ($Item in Get-ChildItem -LiteralPath $Path -Force) {
        Assert-UpdatePath $Item.FullName
        if ($Item.PSIsContainer) { Get-UpdateFile $Item.FullName }
        else { $Item }
    }
}

function Assert-PortableRelativePath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or $Path.Contains('\') -or
        [System.IO.Path]::IsPathRooted($Path)) {
        throw "Unsafe relative path: $Path"
    }
    foreach ($Part in $Path.Split('/')) {
        if ($Part -in @("", ".", "..") -or $Part -match '[<>:"|?*\x00-\x1f]' -or
            $Part -match '[. ]$' -or $Part -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)') {
            throw "Unsafe or non-portable path: $Path"
        }
    }
}

function Remove-UpdateTemporaryDirectory {
    param([string]$Path, [string]$Parent, [string]$Prefix)

    $FullPath = [System.IO.Path]::GetFullPath($Path)
    if ((Split-Path $FullPath -Parent) -ne [System.IO.Path]::GetFullPath($Parent).TrimEnd(
            [System.IO.Path]::DirectorySeparatorChar) -or
        -not (Split-Path $FullPath -Leaf).StartsWith($Prefix, [System.StringComparison]::Ordinal)) {
        throw "Refusing to clean an unexpected temporary directory: $FullPath"
    }
    if (Test-Path -LiteralPath $FullPath) {
        $null = @(Get-UpdateFile $FullPath)
        Remove-Item -LiteralPath $FullPath -Recurse -Force -WhatIf:$false -Confirm:$false
    }
}

function Get-GitHubData {
    param([string]$Uri)

    try {
        $Data = Invoke-RestMethod -Uri $Uri -Headers @{
            Accept = "application/vnd.github+json"
            "X-GitHub-Api-Version" = "2022-11-28"
            "User-Agent" = "skills-utils"
        } -TimeoutSec 60 -ErrorAction Stop
        # Invoke-RestMethod emits JSON arrays as one pipeline object. Enumerate
        # here so repository/release pagination sees items rather than nested arrays.
        return $Data
    }
    catch {
        throw "GitHub request failed for $Uri. Check connectivity and the public API rate limit, then retry. $($_.Exception.Message)"
    }
}

function Read-InstallReceipt {
    param([string]$Directory)
    Assert-UpdatePath $Directory
    $Path = Join-Path $Directory $ReceiptName
    Assert-UpdatePath $Path
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $Receipt = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable
    if ($Receipt.Version -notin @(1, 2) -or $Receipt.Commit -notmatch '^[a-f0-9]{40}$' -or
        $Receipt.Repository -notmatch '^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$' -or
        $Receipt.Files -isnot [System.Collections.IDictionary] -or -not $Receipt.Files.Contains('SKILL.md')) {
        throw "Invalid installation receipt: $Path"
    }
    if ($Receipt.Version -eq 2 -and ($Receipt.Selection -notin @('Stable', 'Latest', 'Pinned') -or
        ($Receipt.Selection -ne 'Latest' -and $Receipt.Tag -notmatch '^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'))) {
        throw "Invalid source selection in receipt: $Path"
    }
    return $Receipt
}

function Resolve-SkillSource {
    param($Repository, [string]$Selection, [string]$Tag)
    $Repo = "$($Repository.owner.login)/$($Repository.name)"
    $Key = "$Repo/$Selection/$Tag"
    if ($SourceCache.ContainsKey($Key)) { return $SourceCache[$Key] }
    if ($Selection -ne 'Latest') {
        $Releases = [System.Collections.Generic.List[object]]::new()
        $ReleasePage = 1
        do {
            $Batch = @(Get-GitHubData "https://api.github.com/repos/$Repo/releases?per_page=100&page=$ReleasePage")
            foreach ($Release in $Batch) {
                if (-not $Release.draft -and -not $Release.prerelease -and
                    $Release.tag_name -cmatch '^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$') {
                    $Releases.Add([pscustomobject]@{ Tag = $Release.tag_name; Major = [bigint]$Matches[1]; Minor = [bigint]$Matches[2]; Patch = [bigint]$Matches[3] })
                }
            }
            $ReleasePage++
        } while ($Batch.Count -eq 100)
        if ($Selection -eq 'Stable') {
            $Best = $Releases | Sort-Object Major, Minor, Patch -Descending | Select-Object -First 1
            if ($null -eq $Best) { throw "No published stable SemVer release in $Repo. No fallback to main." }
            $Tag = $Best.Tag
        }
        elseif ($Tag -cnotin @($Releases | ForEach-Object Tag)) { throw "Published stable release not found: $Repo $Tag" }
        # The commits endpoint dereferences lightweight and annotated tag refs.
        $Ref = [uri]::EscapeDataString("refs/tags/$Tag")
    }
    else { $Ref = [uri]::EscapeDataString($Repository.default_branch); $Tag = $null }
    $Commit = (Get-GitHubData "https://api.github.com/repos/$Repo/commits/$Ref").sha
    if ($Commit -notmatch '^[a-f0-9]{40}$') { throw "GitHub returned an invalid commit." }
    $Source = [pscustomobject]@{ Commit = $Commit; Selection = $Selection; Tag = $Tag }
    $SourceCache[$Key] = $Source
    return $Source
}

function Get-SourceRequest {
    param([string]$RepositoryName, [string]$Target)
    $Known = @{}
    $Roots = @($Target) + @($SearchRoot) | Where-Object { $_ } | Select-Object -Unique
    foreach ($Root in $Roots) {
        $SkillsDirectory = Join-Path $Root 'skills'
        Assert-UpdatePath $SkillsDirectory
        if (-not (Test-Path -LiteralPath $SkillsDirectory)) { continue }
        foreach ($Directory in Get-ChildItem -LiteralPath $SkillsDirectory -Directory -Force) {
            if ($Directory.Name -like 'skills-utils-stage-*' -or $Directory.Name -like 'skills-utils-backup-*') { continue }
            if ($SkillName -and $Directory.Name -notin $SkillName) { continue }
            if ($Directory.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { continue }
            $Receipt = Read-InstallReceipt $Directory.FullName
            if ($null -eq $Receipt -or $Receipt.Repository -ine $RepositoryName) { continue }
            if ($Known.ContainsKey($Directory.Name)) { throw "Multiple installations of $($Directory.Name). Select an explicit TargetRoot without SearchRoot." }
            $Selection = if ($ExactVersion) { 'Pinned' } elseif ($Channel) { $Channel }
                elseif ($Receipt.Version -eq 1) { 'Latest' } else { $Receipt.Selection }
            $Tag = if ($ExactVersion) { $ExactVersion } elseif ($Selection -eq 'Pinned') { $Receipt.Tag } else { $null }
            $Known[$Directory.Name] = $true
            [pscustomobject]@{ Target = $Root; Selection = $Selection; Tag = $Tag; Include = @($Directory.Name); Exclude = @(); Optional = $false }
        }
    }
    if (-not $SkillName -or @($SkillName | Where-Object { -not $Known.ContainsKey($_) }).Count -gt 0) {
        [pscustomobject]@{ Target = $Target; Selection = $(if ($ExactVersion) { 'Pinned' } elseif ($Channel) { $Channel } else { 'Stable' }); Tag = $ExactVersion; Include = @(); Exclude = @($Known.Keys); Optional = ($Known.Count -gt 0 -and -not $Channel -and -not $ExactVersion -and -not $SkillName) }
    }
}

function Expand-SkillArchive {
    param([string]$Archive, [string]$Destination)

    # ZipArchive does not verify entry CRCs on every supported .NET version.
    # Keep the streaming checksum loop in C# to avoid per-byte PowerShell overhead.
    if (-not ("SkillsUtils.ArchiveCrc32" -as [type])) {
        Add-Type -TypeDefinition @'
namespace SkillsUtils
{
    public static class ArchiveCrc32
    {
        private static readonly uint[] Table = CreateTable();

        private static uint[] CreateTable()
        {
            var table = new uint[256];
            for (uint i = 0; i < table.Length; i++)
            {
                uint value = i;
                for (int bit = 0; bit < 8; bit++)
                    value = (value & 1) != 0 ? 0xEDB88320u ^ (value >> 1) : value >> 1;
                table[i] = value;
            }
            return table;
        }

        public static uint Update(uint crc, byte[] buffer, int count)
        {
            for (int i = 0; i < count; i++)
                crc = Table[(crc ^ buffer[i]) & 0xFF] ^ (crc >> 8);
            return crc;
        }
    }
}
'@
    }
    if ((Get-Item -LiteralPath $Archive).Length -gt 100MB) {
        throw "Repository archive exceeds the 100 MB download limit."
    }
    $Zip = [System.IO.Compression.ZipFile]::OpenRead($Archive)
    try {
        if ($Zip.Entries.Count -gt 20000) { throw "Repository archive contains too many entries." }
        $Total = 0L
        $Names = @{}
        $Roots = @{}
        # Validate the complete archive before extracting any entry.
        foreach ($Entry in $Zip.Entries) {
            $Name = $Entry.FullName.TrimEnd('/')
            Assert-PortableRelativePath $Name
            if ($Names.ContainsKey($Name)) { throw "Duplicate archive path: $Name" }
            $Names[$Name] = $true
            $Roots[$Name.Split('/')[0]] = $true
            $UnixType = ($Entry.ExternalAttributes -shr 16) -band 0xF000
            if ($UnixType -notin @(0, 0x8000, 0x4000) -or ($Entry.ExternalAttributes -band 0x400)) {
                throw "Links or special files are not allowed in repository archives: $Name"
            }
            $Total += $Entry.Length
            if ($Total -gt 256MB) { throw "Repository archive exceeds the 256 MB expanded limit." }
        }
        if ($Roots.Count -ne 1) { throw "Expected a GitHub archive with one repository root." }
        $ExpandedBytes = 0L
        $Buffer = [byte[]]::new(65536)
        foreach ($Entry in $Zip.Entries) {
            $OutputPath = Join-Path $Destination $Entry.FullName.TrimEnd('/')
            if ($Entry.FullName.EndsWith('/')) {
                $null = [System.IO.Directory]::CreateDirectory($OutputPath)
                continue
            }
            $null = [System.IO.Directory]::CreateDirectory((Split-Path $OutputPath -Parent))
            $InputStream = $Entry.Open()
            $OutputStream = $null
            try {
                $OutputStream = [System.IO.File]::Open($OutputPath, [System.IO.FileMode]::CreateNew)
                $EntryBytes = 0L
                $Crc = [uint32]::MaxValue
                while (($ReadCount = $InputStream.Read($Buffer, 0, $Buffer.Length)) -gt 0) {
                    $EntryBytes += $ReadCount
                    $ExpandedBytes += $ReadCount
                    if ($ExpandedBytes -gt 256MB -or $EntryBytes -gt $Entry.Length) {
                        throw "Expanded archive data exceeds its declared size or the extraction limit."
                    }
                    $OutputStream.Write($Buffer, 0, $ReadCount)
                    $Crc = [SkillsUtils.ArchiveCrc32]::Update($Crc, $Buffer, $ReadCount)
                }
                if ($EntryBytes -ne $Entry.Length) { throw "Archive entry size mismatch: $($Entry.FullName)" }
                if (($Crc -bxor [uint32]::MaxValue) -ne $Entry.Crc32) {
                    throw "Archive entry checksum mismatch: $($Entry.FullName)"
                }
            }
            finally {
                if ($null -ne $OutputStream) { $OutputStream.Dispose() }
                $InputStream.Dispose()
            }
        }
        Join-Path $Destination @($Roots.Keys)[0]
    }
    finally { $Zip.Dispose() }
}

function Select-NumberedItem {
    param([object[]]$Items, [string]$LabelProperty, [string]$Prompt)

    if ($Items.Count -eq 0) { throw "There are no items to select." }
    for ($Index = 0; $Index -lt $Items.Count; $Index++) {
        Write-Host ("{0}. {1}" -f ($Index + 1), $Items[$Index].$LabelProperty)
    }
    $Answer = Read-Host "$Prompt (comma-separated numbers; empty cancels)"
    if ([string]::IsNullOrWhiteSpace($Answer)) { throw "Selection cancelled; no installations changed." }
    $Selected = @{}
    foreach ($Part in $Answer.Split(',')) {
        $Number = 0
        if (-not [int]::TryParse($Part.Trim(), [ref]$Number) -or $Number -lt 1 -or $Number -gt $Items.Count) {
            throw "Invalid selection: $Part. No installations changed."
        }
        if (-not $Selected.ContainsKey($Number)) { $Items[$Number - 1]; $Selected[$Number] = $true }
    }
}

function Get-InstallAssessment {
    param($Skill, [string]$Destination)

    Assert-UpdatePath $Destination
    $InstalledCommit = $null
    $ReceiptHash = $null
    $MetadataMatches = $false
    $SeenTags = @{}
    $OldFiles = @{}
    $ExistingFiles = @{}
    if (Test-Path -LiteralPath $Destination) {
        if (-not (Test-Path -LiteralPath $Destination -PathType Container)) {
            throw "The skill destination is not a directory."
        }
        foreach ($File in Get-UpdateFile $Destination) {
            $Relative = [System.IO.Path]::GetRelativePath($Destination, $File.FullName).Replace('\', '/')
            Assert-PortableRelativePath $Relative
            if ($Relative -ne $ReceiptName) {
                $ExistingFiles[$Relative] = (Get-FileHash -LiteralPath $File.FullName -Algorithm SHA256).Hash
            }
        }
        $ReceiptPath = Join-Path $Destination $ReceiptName
        if (Test-Path -LiteralPath $ReceiptPath -PathType Leaf) {
            $Receipt = Read-InstallReceipt $Destination
            if ($Receipt.Repository -ine $Skill.Repository) { throw "Installation belongs to another repository." }
            $ReceiptHash = (Get-FileHash -LiteralPath $ReceiptPath -Algorithm SHA256).Hash
            if ($Receipt.ContainsKey('SeenTags')) {
                if ($Receipt.SeenTags -isnot [System.Collections.IDictionary]) { throw 'Invalid release history.' }
                foreach ($Tag in $Receipt.SeenTags.Keys) {
                    if ($Tag -cnotmatch '^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$' -or $Receipt.SeenTags[$Tag] -notmatch '^[a-f0-9]{40}$') { throw 'Invalid release history.' }
                    $SeenTags[$Tag] = $Receipt.SeenTags[$Tag]
                }
            }
            if ($Receipt.Version -eq 2 -and $Receipt.Tag) { $SeenTags[$Receipt.Tag] = $Receipt.Commit }
            if ($Skill.Tag -and $SeenTags.ContainsKey($Skill.Tag) -and $SeenTags[$Skill.Tag] -cne $Skill.Commit) {
                throw "Previously observed release tag moved: $($Skill.Tag)"
            }
            $MetadataMatches = $Receipt.Version -eq 2 -and $Receipt.Selection -ceq $Skill.Selection -and [string]$Receipt.Tag -ceq [string]$Skill.Tag
            if ($Receipt.Version -eq 2 -and $Receipt.Tag) {
                if ($Receipt.Tag -ceq $Skill.Tag -and $Receipt.Commit -cne $Skill.Commit) { throw "Release tag moved: $($Skill.Tag)" }
                if ($Skill.Tag) {
                    $OldVersion = @($Receipt.Tag.Substring(1).Split('.') | ForEach-Object { [bigint]$_ })
                    $NewVersion = @($Skill.Tag.Substring(1).Split('.') | ForEach-Object { [bigint]$_ })
                    $Comparison = 0
                    for ($Part = 0; $Part -lt 3 -and $Comparison -eq 0; $Part++) { $Comparison = $NewVersion[$Part].CompareTo($OldVersion[$Part]) }
                    if ($Comparison -lt 0 -and -not $AllowDowngrade) { throw "Downgrade requires -AllowDowngrade for this repository." }
                    if ($NewVersion[0] -gt $OldVersion[0] -and -not $AllowMajorUpgrade) { throw "Major upgrade requires -AllowMajorUpgrade for this repository." }
                }
            }
            $InstalledCommit = $Receipt.Commit
            foreach ($Relative in $Receipt.Files.Keys) {
                Assert-PortableRelativePath $Relative
                if ($Receipt.Files[$Relative] -notmatch '^[A-Fa-f0-9]{64}$' -or
                    -not $ExistingFiles.ContainsKey($Relative) -or $ExistingFiles[$Relative] -ne $Receipt.Files[$Relative]) {
                    throw "Local modification or missing managed file: $Relative"
                }
                $OldFiles[$Relative] = $Receipt.Files[$Relative]
            }
        }
        else {
            # A legacy installation can be adopted only when its skill files match.
            foreach ($Relative in $Skill.Files.Keys) {
                if (-not $ExistingFiles.ContainsKey($Relative) -or $ExistingFiles[$Relative] -ne $Skill.Files[$Relative]) {
                    throw "Unmanaged installation differs from the source. Back it up and move it aside before installing."
                }
            }
        }
        foreach ($Relative in $Skill.Files.Keys) {
            if ($ExistingFiles.ContainsKey($Relative) -and -not $OldFiles.ContainsKey($Relative) -and
                $ExistingFiles[$Relative] -ne $Skill.Files[$Relative]) {
                throw "An unmanaged local file would be overwritten: $Relative"
            }
        }
    }
    $ExtraCount = @($ExistingFiles.Keys | Where-Object { -not $Skill.Files.ContainsKey($_) }).Count
    if ($InstalledCommit -eq $Skill.Commit) {
        foreach ($Relative in $Skill.Files.Keys) {
            if (-not $ExistingFiles.ContainsKey($Relative) -or $ExistingFiles[$Relative] -ne $Skill.Files[$Relative]) {
                throw "Installed files do not match the recorded source commit: $Relative"
            }
        }
    }
    $Status = if (-not (Test-Path -LiteralPath $Destination)) { "Install" }
        elseif ($InstalledCommit -eq $Skill.Commit -and $MetadataMatches -and (-not $RemoveExtraFiles -or $ExtraCount -eq 0)) { "Unchanged" }
        elseif ($null -eq $InstalledCommit) { "Adopt" }
        else { "Update" }
    [pscustomobject]@{ Status = $Status; InstalledCommit = $InstalledCommit; ReceiptHash = $ReceiptHash; SeenTags = $SeenTags; OldFiles = $OldFiles; ExistingFiles = $ExistingFiles; ExtraCount = $ExtraCount }
}

$Targets = @()
if ($PSCmdlet.ParameterSetName -eq "Current") {
    $Targets = @($TargetRoot | ForEach-Object { [System.IO.Path]::GetFullPath($_) } | Select-Object -Unique)
}
else {
    $Profiles = @(& (Join-Path $PSScriptRoot "Get-AgentSkillUserProfile.ps1"))
    if ($Profiles.Count -eq 0) { throw "No existing non-system user profiles were found." }
    if ($SelectUser) {
        foreach ($Profile in $Profiles) {
            $Profile | Add-Member -NotePropertyName Label -NotePropertyValue "$($Profile.Account) [$($Profile.SID)] - $($Profile.ProfilePath)"
        }
        $Profiles = @(Select-NumberedItem $Profiles "Label" "Select user profiles")
    }
    else {
        foreach ($Sid in $UserSid) {
            if ($Sid -notin $Profiles.SID) { throw "No existing non-system profile was found for SID: $Sid" }
        }
        $Profiles = @($Profiles | Where-Object { $_.SID -in $UserSid })
    }
    $CurrentSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    if (@($Profiles | Where-Object { $_.SID -ne $CurrentSid }).Count -gt 0 -and -not $List -and -not $WhatIfPreference) {
        $Principal = [System.Security.Principal.WindowsPrincipal]::new([System.Security.Principal.WindowsIdentity]::GetCurrent())
        if (-not $Principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)) {
            throw "Updating other profiles requires an elevated PowerShell session. No passwords or runas are needed."
        }
    }
    $Targets = @($Profiles | ForEach-Object { Join-Path $_.ProfilePath $ProfileDirectory } | Select-Object -Unique)
}
if ($Targets.Count -eq 0) { throw "No installation targets selected." }
foreach ($Target in $Targets) { Assert-UpdatePath $Target }

$TempParent = [System.IO.Path]::GetTempPath()
$TempRoot = Join-Path $TempParent "skills-utils-update-$([guid]::NewGuid().ToString('N'))"
$null = [System.IO.Directory]::CreateDirectory($TempRoot)
$Skills = [System.Collections.Generic.List[object]]::new()
$Results = [System.Collections.Generic.List[object]]::new()
$SourceCache = @{}
$PackageCache = @{}
try {
    $Page = 1
    do {
        $Repositories = @(Get-GitHubData "https://api.github.com/users/$Owner/repos?type=owner&per_page=100&page=$Page")
        foreach ($Repository in $Repositories) {
            if ($Repository.name -notlike $RepositoryPattern -or $Repository.archived -or $Repository.disabled) { continue }
            if ($Repository.name -notmatch '^[A-Za-z0-9._-]+$' -or $Repository.owner.login -ine $Owner) {
                throw "GitHub returned an unexpected repository identity."
            }
            Assert-PortableRelativePath $Repository.name
            $RepositoryName = "$($Repository.owner.login)/$($Repository.name)"
            foreach ($Target in $Targets) {
            try { $Requests = @(Get-SourceRequest $RepositoryName $Target) }
            catch {
                $Results.Add([pscustomobject]@{ Skill = $null; Repository = $RepositoryName; Target = $Target; Commit = $null; InstalledCommit = $null; Status = 'Failed'; Detail = $_.Exception.Message })
                continue
            }
            foreach ($Request in $Requests) {
            try {
                $Resolved = Resolve-SkillSource $Repository $Request.Selection $Request.Tag
                $Commit = $Resolved.Commit
                $CacheKey = "$RepositoryName/$Commit"
                if (-not $PackageCache.ContainsKey($CacheKey)) {
                $Package = [System.Collections.Generic.List[object]]::new()
                $DownloadRoot = Join-Path $TempRoot "$($Repository.name)-$Commit"
                $null = [System.IO.Directory]::CreateDirectory($DownloadRoot)
                $Archive = Join-Path $DownloadRoot "repository.zip"
                Invoke-WebRequest -Uri "https://codeload.github.com/$RepositoryName/zip/$Commit" -OutFile $Archive -TimeoutSec 60 -ErrorAction Stop
                $SourceRoot = Expand-SkillArchive $Archive (Join-Path $DownloadRoot "source")
                $Candidates = @()
                if (Test-Path -LiteralPath (Join-Path $SourceRoot "SKILL.md") -PathType Leaf) {
                    $Candidates = @($SourceRoot)
                }
                else {
                    $Candidates = @(foreach ($Directory in Get-ChildItem -LiteralPath $SourceRoot -Directory) {
                        if ($Directory.Name -eq "skills") {
                            Get-ChildItem -LiteralPath $Directory.FullName -Directory | ForEach-Object { $_.FullName }
                        }
                        elseif ($Directory.Name -notin @("tests", "fixtures", "examples", "scripts", "tools", "docs", "references", "assets", "agents") -and -not $Directory.Name.StartsWith('.')) {
                            $Directory.FullName
                        }
                    })
                }
                $Found = 0
                foreach ($Candidate in $Candidates) {
                    $EntryPoint = Join-Path $Candidate "SKILL.md"
                    if (-not (Test-Path -LiteralPath $EntryPoint -PathType Leaf)) { continue }
                    $PreparedRoot = Join-Path $DownloadRoot "prepared-$Found"
                    & $CopyScript -SourceRoot $Candidate -TargetRoot $PreparedRoot -WhatIf:$false -Confirm:$false 6>$null
                    $Prepared = @(Get-ChildItem -LiteralPath (Join-Path $PreparedRoot "skills") -Directory)
                    if ($Prepared.Count -ne 1) { throw "Expected exactly one prepared skill." }
                    $Files = @{}
                    foreach ($File in Get-UpdateFile $Prepared[0].FullName) {
                        $Relative = [System.IO.Path]::GetRelativePath($Prepared[0].FullName, $File.FullName).Replace('\', '/')
                        $Files[$Relative] = (Get-FileHash -LiteralPath $File.FullName -Algorithm SHA256).Hash
                    }
                    $Package.Add([pscustomobject]@{
                        Name = $Prepared[0].Name; Repository = $RepositoryName; Commit = $Commit
                        Source = $Prepared[0].FullName; Files = $Files; Label = "$($Prepared[0].Name) ($RepositoryName)"
                    })
                    $Found++
                }
                $PackageCache[$CacheKey] = $Package.ToArray()
                if ($Found -eq 0) { Write-Host "No skills found in $RepositoryName; skipped." }
                }
                foreach ($PreparedSkill in $PackageCache[$CacheKey]) {
                    if ($Request.Include.Count -gt 0 -and $PreparedSkill.Name -notin $Request.Include) { continue }
                    if ($PreparedSkill.Name -in $Request.Exclude) { continue }
                    $Skill = $PreparedSkill.PSObject.Copy()
                    $Skill | Add-Member -NotePropertyName TargetRoot -NotePropertyValue $Request.Target
                    $Skill | Add-Member -NotePropertyName Selection -NotePropertyValue $Resolved.Selection
                    $Skill | Add-Member -NotePropertyName Tag -NotePropertyValue $Resolved.Tag
                    if ($SearchRoot) {
                        $ExistingRoots = @(@($TargetRoot) + @($SearchRoot) | Select-Object -Unique | Where-Object {
                            Test-Path -LiteralPath (Join-Path (Join-Path $_ 'skills') $Skill.Name)
                        })
                        if ($ExistingRoots.Count -gt 1) { throw "Multiple installations of $($Skill.Name). Select an explicit TargetRoot without SearchRoot." }
                        if ($ExistingRoots.Count -eq 1) { $Skill.TargetRoot = $ExistingRoots[0] }
                    }
                    $Skills.Add($Skill)
                }
                foreach ($RequiredName in $Request.Include) {
                    if ($RequiredName -notin @($PackageCache[$CacheKey] | ForEach-Object Name)) {
                        throw "Installed skill $RequiredName is missing from the selected source; installation retained."
                    }
                }
            }
            catch {
                $FailureStatus = if ($Request.Optional -and $_.Exception.Message -like 'No published stable SemVer release*') { 'Skipped' } else { 'Failed' }
                $Results.Add([pscustomobject]@{ Skill = $null; Repository = $RepositoryName; Target = $Request.Target; Commit = $null; InstalledCommit = $null; Status = $FailureStatus; Detail = $_.Exception.Message })
            }
            }
            }
        }
        $Page++
    } while ($Repositories.Count -eq 100)

    $SelectedSkills = @($Skills | Where-Object { -not $SkillName -or $_.Name -in $SkillName } | Sort-Object Name, Repository)
    if ($SkillName) {
        foreach ($RequestedName in $SkillName) {
            if ($RequestedName -notin @($SelectedSkills | ForEach-Object { $_.Name })) {
                throw "Requested skill was not found: $RequestedName"
            }
        }
    }
    if ($Interactive) { $SelectedSkills = @(Select-NumberedItem $SelectedSkills "Label" "Select skills") }
    $Collisions = @($SelectedSkills | Group-Object { "$([System.IO.Path]::GetFullPath($_.TargetRoot))/$($_.Name)" } | Where-Object Count -gt 1 | ForEach-Object Name)
    $Plan = [System.Collections.Generic.List[object]]::new()
    foreach ($Skill in $SelectedSkills) {
        foreach ($Target in @($Skill.TargetRoot)) {
            $Destination = Join-Path (Join-Path $Target "skills") $Skill.Name
            $Row = [pscustomobject]@{ Skill = $Skill.Name; Repository = $Skill.Repository; Target = $Destination; Commit = $Skill.Commit; InstalledCommit = $null; Status = "Conflict"; Detail = "" }
            try {
                if ("$([System.IO.Path]::GetFullPath($Target))/$($Skill.Name)" -in $Collisions) { throw "Multiple source directories provide this skill name. Select a single repository." }
                $Assessment = Get-InstallAssessment $Skill $Destination
                $Row.Status = $Assessment.Status
                $Row.InstalledCommit = $Assessment.InstalledCommit
                $Row.Detail = if ($RemoveExtraFiles) { "$($Assessment.ExtraCount) extra files will be removed." } else { "$($Assessment.ExtraCount) extra files will be preserved." }
                $Plan.Add([pscustomobject]@{ Skill = $Skill; TargetRoot = $Target; Row = $Row })
            }
            catch { $Row.Detail = $_.Exception.Message }
            $Results.Add($Row)
        }
    }
    foreach ($Row in $Results) { Write-Host "$($Row.Status): $($Row.Repository) / $($Row.Skill) -> $($Row.Target) $($Row.Detail)" }
    if (-not $List) {
        foreach ($Item in $Plan) {
            $Row = $Item.Row
            if ($Row.Status -eq "Unchanged") { continue }
            if (-not $PSCmdlet.ShouldProcess($Row.Target, "$($Row.Status) $($Row.Skill) at $($Row.Commit); $($Row.Detail)")) {
                $Row.Status = if ($WhatIfPreference) { "WhatIf" } else { "Skipped" }
                continue
            }
            $Lock = $null
            $Stage = $null
            $Backup = $null
            $Installed = $false
            try {
                Assert-UpdatePath $Item.TargetRoot
                $null = [System.IO.Directory]::CreateDirectory($Item.TargetRoot)
                $LockPath = Join-Path $Item.TargetRoot ".skills-utils.lock"
                Assert-UpdatePath $LockPath
                $Lock = [System.IO.File]::Open($LockPath, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
                $Assessment = Get-InstallAssessment $Item.Skill $Row.Target
                $SkillsRoot = Join-Path $Item.TargetRoot "skills"
                Assert-UpdatePath $SkillsRoot
                $null = [System.IO.Directory]::CreateDirectory($SkillsRoot)
                $Stage = Join-Path $SkillsRoot "skills-utils-stage-$([guid]::NewGuid().ToString('N'))"
                $null = [System.IO.Directory]::CreateDirectory($Stage)
                $StagedSkill = Join-Path (Join-Path $Stage "skills") $Row.Skill
                if (Test-Path -LiteralPath $Row.Target) {
                    $null = [System.IO.Directory]::CreateDirectory($StagedSkill)
                    foreach ($File in Get-UpdateFile $Row.Target) {
                        $Relative = [System.IO.Path]::GetRelativePath($Row.Target, $File.FullName)
                        $Destination = Join-Path $StagedSkill $Relative
                        $null = [System.IO.Directory]::CreateDirectory((Split-Path $Destination -Parent))
                        Copy-Item -LiteralPath $File.FullName -Destination $Destination -Force -WhatIf:$false -Confirm:$false
                    }
                }
                & $CopyScript -SourceRoot $Item.Skill.Source -TargetRoot $Stage -RemoveExtraFiles:$RemoveExtraFiles -WhatIf:$false -Confirm:$false 6>$null
                $ManagedFiles = @{}
                if (-not $RemoveExtraFiles) {
                    foreach ($Relative in $Assessment.OldFiles.Keys) { $ManagedFiles[$Relative] = $Assessment.OldFiles[$Relative] }
                }
                foreach ($Relative in $Item.Skill.Files.Keys) { $ManagedFiles[$Relative] = $Item.Skill.Files[$Relative] }
                $SeenTags = @{} + $Assessment.SeenTags
                if ($Item.Skill.Tag) { $SeenTags[$Item.Skill.Tag] = $Row.Commit }
                $Receipt = @{ Version = 2; Repository = $Row.Repository; Commit = $Row.Commit; Selection = $Item.Skill.Selection; Tag = $Item.Skill.Tag; SeenTags = $SeenTags; Files = $ManagedFiles }
                $Receipt | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $StagedSkill $ReceiptName) -Encoding utf8 -Confirm:$false
                # Verify prepared bytes before changing the installed directory.
                $null = Get-InstallAssessment $Item.Skill $StagedSkill
                $Latest = Get-InstallAssessment $Item.Skill $Row.Target
                if ($Latest.ReceiptHash -ne $Assessment.ReceiptHash -or $Latest.InstalledCommit -ne $Assessment.InstalledCommit -or
                    $Latest.ExistingFiles.Count -ne $Assessment.ExistingFiles.Count) {
                    throw "The installation changed during preparation. Retry the update."
                }
                foreach ($Relative in $Assessment.ExistingFiles.Keys) {
                    if (-not $Latest.ExistingFiles.ContainsKey($Relative) -or
                        $Latest.ExistingFiles[$Relative] -ne $Assessment.ExistingFiles[$Relative]) {
                        throw "The installation changed during preparation: $Relative. Retry the update."
                    }
                }
                Assert-UpdatePath $Row.Target
                if (Test-Path -LiteralPath $Row.Target) {
                    $Backup = Join-Path $SkillsRoot "skills-utils-backup-$([guid]::NewGuid().ToString('N'))"
                    Move-Item -LiteralPath $Row.Target -Destination $Backup -Confirm:$false
                }
                try { Move-Item -LiteralPath $StagedSkill -Destination $Row.Target -Confirm:$false; $Installed = $true }
                catch {
                    if ($Backup) { Move-Item -LiteralPath $Backup -Destination $Row.Target -Confirm:$false; $Backup = $null }
                    throw
                }
                $Row.Status = if ($Assessment.Status -eq "Install") { "Installed" } elseif ($Assessment.Status -eq "Adopt") { "Adopted" } else { "Updated" }
            }
            catch { $Row.Status = "Failed"; $Row.Detail = $_.Exception.Message }
            finally {
                try {
                    if ($Stage) { Remove-UpdateTemporaryDirectory $Stage $SkillsRoot "skills-utils-stage-" }
                    if ($Backup -and $Installed) { Remove-UpdateTemporaryDirectory $Backup $SkillsRoot "skills-utils-backup-" }
                    elseif ($Backup) { $Row.Detail += " Recovery copy retained at $Backup." }
                }
                catch { $Row.Status = "Failed"; $Row.Detail += " Cleanup failed: $($_.Exception.Message)" }
                if ($null -ne $Lock) { $Lock.Dispose() }
            }
        }
    }
    $Results.ToArray()
    if (@($Results | Where-Object { $_.Status -in @("Failed", "Conflict") }).Count -gt 0) {
        throw "One or more skills could not be processed. Review the result rows; successful installations are retained."
    }
}
finally {
    Remove-UpdateTemporaryDirectory $TempRoot $TempParent "skills-utils-update-"
}
