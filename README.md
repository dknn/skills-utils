# skills-utils

Reusable utilities for maintaining agent skill repositories.

This repository is the authoritative development source for the utilities.
Repositories that use a utility should bundle a versioned copy so their users
do not need to clone `skills-utils` or download code at runtime.

## Update all dknn skills

Install `skills/update-dknn-skills` into your agent's skills directory, then invoke
`$update-dknn-skills`. Its bundled wrapper checks and updates public `dknn/skills-*`
repositories and can install its own newer version. PowerShell 7 is required.

The wrapper discovers existing `.agents` and `.codex` installations, including
`CODEX_HOME`. New skills go to the current Codex root. Ambiguous duplicate copies
are reported; select an explicit `-TargetRoot` to resolve them. An explicit root
disables automatic discovery. Other users are never selected automatically.

From a verified checkout, bootstrap the skill with:

```powershell
./scripts/Copy-AgentSkillToUserProfile.ps1 -SourceRoot ./skills/update-dknn-skills `
    -TargetRoot $(if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $HOME '.codex' })
```

The named adapter snapshots its installed scripts before running, so self-update
cannot replace helpers while they are executing. Its engine remains generic.
After changing engine scripts, run `./scripts/Build-UpdateSkill.ps1` and commit
the refreshed bundle. Validation checks exact bundle parity without regenerating it.

## Install or update skills from GitHub

`scripts/Update-AgentSkill.ps1` discovers public repositories belonging to a
GitHub account, selects names matching `skills-*`, and installs their skills.
Supply the account through `-Owner`; no account name is built into the utility.
It requires PowerShell 7+, with no Git, GitHub CLI, or additional modules.

Preview updates for the current user, then apply them:

```powershell
pwsh -NoProfile -File ./scripts/Update-AgentSkill.ps1 -Owner example-owner -WhatIf
pwsh -NoProfile -File ./scripts/Update-AgentSkill.ps1 -Owner example-owner
```

`-List` returns the installation plan without changing installed files.
`-Interactive` displays a numbered skill list; enter comma-separated numbers.
An empty or invalid selection cancels. Without selection parameters, all
discovered skills are included. `-SkillName` selects explicit skill names, and
`-RepositoryPattern` changes the repository filter. Archived and disabled
repositories are excluded. Repositories without a supported skill layout are
reported and skipped.

Supported skill entry points are `SKILL.md` at the repository root,
`<directory>/SKILL.md`, and `skills/<directory>/SKILL.md`. Conventional test,
example, documentation, and tooling directories are excluded from discovery.
Skill names come from YAML frontmatter, including plain or quoted names.
Duplicate names across selected sources are conflicts, including case-only
differences. Select one source using `-RepositoryPattern` to resolve them.

### Select Windows user profiles

List existing non-system profiles:

```powershell
pwsh -NoProfile -File ./scripts/Get-AgentSkillUserProfile.ps1
```

Select profiles and skills from numbered lists:

```powershell
pwsh -NoProfile -File ./scripts/Update-AgentSkill.ps1 `
    -Owner example-owner -SelectUser -Interactive -WhatIf
```

Run without `-WhatIf` to apply the selected updates. Use an elevated PowerShell
session when updating other users. The utility copies files to the selected
profiles; it never requests their passwords, impersonates users, or runs
`runas`. It never changes directory ownership or access rules to bypass an
access-denied error.

`-UserSid` selects profiles by their stable Windows identifiers without a
menu. Profile discovery excludes system profiles and accounts without an
existing profile directory. Account names and profile paths remain local.
The Windows profile modes target `.agents/skills` by default; specify
`-ProfileDirectory .codex` to target `.codex/skills` instead.

Current-user installation works on Windows, Linux, and macOS. For a custom
location, pass the agent directory as `-TargetRoot` (the utility appends
`skills/<skill-name>`):

```powershell
./scripts/Update-AgentSkill.ps1 -Owner example-owner `
    -TargetRoot (Join-Path $HOME ".codex") -SkillName example-skill
```

Custom `CODEX_HOME` locations are not inferred for other users. Supply their
intended agent directories explicitly through `-TargetRoot`. That parameter
also accepts multiple directories when called from PowerShell. Installing in
another profile may require elevation and suitable filesystem permissions.

### Versions, conflicts, and failures

New installations use **Stable**, the highest published stable `vMAJOR.MINOR.PATCH`
release by numeric SemVer order. Drafts and prereleases are excluded. Missing
releases are reported without falling back to a branch. **Latest** explicitly
tracks the default-branch commit. Each repository is versioned independently.

Receipt schema 2 records source selection, release tag, commit, previously seen
release tags, and SHA-256 hashes of managed files. Schema-1 receipts migrate to
Latest, preserving their original behavior. An installation without a receipt
uses the selected source and can only be adopted when incoming files match.

Normal updates preserve each installation's channel or pin. Change the source
for one explicitly selected repository:

```powershell
./scripts/Update-AgentSkill.ps1 -Owner example-owner -RepositoryPattern skills-demo -Channel Stable
./scripts/Update-AgentSkill.ps1 -Owner example-owner -RepositoryPattern skills-demo -Channel Latest
./scripts/Update-AgentSkill.ps1 -Owner example-owner -RepositoryPattern skills-demo -ExactVersion v1.0.0
```

Use `-AllowMajorUpgrade` or `-AllowDowngrade` explicitly with one repository when
crossing those version boundaries. A known tag changing commit is rejected.
Archives are downloaded by resolved commit, once per repository and SHA per
invocation, and reused across targets. File timestamps and compressed archive
hashes do not determine versions. No compilation is required.

- Unchanged installations are verified and skipped. Discovery still downloads
  archives to find skills and verify their current content.
- Modified or missing managed files cause a conflict. Unmanaged files that
  would be overwritten also cause a conflict. Back up and move a conflicting
  skill directory aside if you intend to replace it; there is no force override.
- An existing installation without a receipt is adopted only if all incoming
  files already match. Other files are preserved by default.
- Files removed upstream and unrelated local files are preserved by default.
  Use `-RemoveExtraFiles` explicitly to remove extra files within the selected
  skill, after reviewing the preview. Other skills are not removed.
- Downloaded scripts are copied as skill assets but never executed by the
  updater. Only the local, reviewed copy utility performs installation.
- Downloads and archives are checked for unsafe paths, collisions, links,
  special files, and size limits before installation. Symlinks and Windows
  junctions in source or destination paths are rejected.
- Updates are prepared alongside the destination and verified before swapping
  directories. Existing file hashes are checked again before replacement to
  detect edits during preparation. A failed swap attempts to restore the previous directory.
  Recovery copies are retained and reported if restoration fails. A per-target
  lock prevents concurrent runs of this updater from modifying the same target.

Stop editors and other tools from modifying the selected skill directories
during an update. The lock coordinates this utility, not other programs.

`-List` and `-WhatIf` still access GitHub and use temporary download directories;
they do not write to installation targets. Public API rate limits apply.
Network errors are reported with a retry instruction. Network requests have a
60-second timeout. Downloaded archives larger than 100 MB are rejected before
extraction. Extraction is limited to 256 MB of actual expanded data and 20,000
entries; declared sizes and ZIP entry checksums are also validated. A small
embedded C# checksum loop uses PowerShell's built-in `Add-Type`; no package is
installed. Environments that prohibit `Add-Type` will report an archive failure
before installing anything.

The updater returns one result per skill and target with source commit,
previous commit, status, and details. Repository download failures appear as
separate failure rows. Any conflict or failure produces a terminating error
after reporting results; successful installations in other targets remain.
This is not a transaction across all users and skills.

## Copy a skill to the current user profile

`Copy-AgentSkillToUserProfile.ps1` reads the skill name from `SKILL.md` and
copies the complete skill to:

```text
$HOME/.agents/skills/<skill-name>
```

Run it from this repository with the source skill repository as `-SourceRoot`:

```powershell
$SourceRoot = "C:\path\to\a-skill-repository"

pwsh -NoProfile -File .\scripts\Copy-AgentSkillToUserProfile.ps1 `
    -SourceRoot $SourceRoot
```

If a repository contains multiple skills, point to the directory containing
the selected skill's `SKILL.md`:

```powershell
$SourceRoot = "C:\path\to\a-skill-collection\skills\example-skill"

pwsh -NoProfile -File .\scripts\Copy-AgentSkillToUserProfile.ps1 `
    -SourceRoot $SourceRoot
```

The script copies `SKILL.md` and the conventional `scripts`, `references`,
`assets`, and `agents` directories when present. Matching files are
overwritten. Other installed skills and unrelated files are not changed.
It supports `-WhatIf`, rejects overlapping source and target directories, and
rejects symlinks and junctions before copying or removing files.

## Bundle the utility in a skill repository

Copy `scripts/Copy-AgentSkillToUserProfile.ps1` into the consuming
repository's `tools` directory. Commit that local copy together with a small
root wrapper that supplies the repository-specific `-SourceRoot`.

The consuming repository then remains self-contained. Updating the utility is
an intentional source change: replace the bundled copy, review the diff, and
run both repositories' tests before committing it.

Use `-RemoveExtraFiles` only when the installed copy of the selected skill
should exactly match its source files:

```powershell
pwsh -NoProfile -File .\scripts\Copy-AgentSkillToUserProfile.ps1 `
    -SourceRoot $SourceRoot `
    -RemoveExtraFiles
```

## Development

Repository governance and contribution rules are documented in `AGENTS.md`
and `CONTRIBUTING.md`. Run the complete validation suite with:

```powershell
pwsh -NoProfile -File .\scripts\Invoke-Validation.ps1
```

The command:

1. installs the pinned actionlint release into the ignored `.tools` directory,
2. verifies the downloaded archive's SHA-256 before execution,
3. validates GitHub Actions workflow syntax and semantics,
4. parses every repository PowerShell file, and
5. runs the isolated copy, profile-discovery, and updater regression tests.

Updater tests replace network commands with local fixtures. Profile tests use
simulated CIM data. No regression test downloads skills or writes to a real
user profile. On non-Windows systems the profile test verifies the platform
error; Windows CI checks profile filtering.

Internet access is needed only when the pinned actionlint executable is not
already installed locally. GitHub Actions runs the same validation command on
Windows and Linux for every push and pull request. Dependabot checks weekly
for updates to pinned GitHub Actions references.

The actionlint version and official release checksums are stored in
`config/actionlint.json`. Update the version, filenames, and checksums together,
then run the complete validation suite on a clean `.tools` directory.

## Security

See `SECURITY.md` for private vulnerability reporting and the repository's
safety expectations.

## License

Released under the MIT License. See `LICENSE`.

## Versions and releases

This repository is versioned independently with stable SemVer tags
`vMAJOR.MINOR.PATCH`. All skills in the repository share that release. Skill
Markdown and PowerShell are distributed as validated source, without compilation.

Use a patch release for compatible corrections, a minor release for compatible
features, and a major release for breaking instructions, interfaces, or packaging.
The initial release is `v1.0.0`; do not edit a published tag to fix a release.

Merge a pull request after both `Validate (windows-latest)` and
`Validate (ubuntu-latest)` pass. Then run **Actions > Release > Run workflow**
on `main` with the new version. The workflow validates that exact commit again,
requires immutable releases, creates a new tag, prepares a draft, and publishes
it. A failed publication can leave a tag or draft for manual inspection; the
workflow never overwrites an existing tag. Publish a new version for corrections.

Repository rules require PRs, passing checks, an up-to-date branch, and resolved
review conversations on main. Force pushes and deletion are blocked. There are
no bypass actors and no required external approvals, permitting solo maintenance.
Version tags cannot be updated or deleted; releases are immutable after publication.

Use `$update-dknn-skills` from [skills-utils](https://github.com/dknn/skills-utils)
to install or update. New installations use Stable; Latest explicitly follows
the default branch. Installed source choices and pinned versions persist.
Commit SHAs and managed-file hashes identify installed content, not timestamps.
