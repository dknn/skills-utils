# skills-utils

Reusable utilities for maintaining agent skill repositories.

This repository is the authoritative development source for the utilities.
Repositories that use a utility should bundle a versioned copy so their users
do not need to clone `skills-utils` or download code at runtime.

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
5. runs the isolated regression tests.

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
