---
name: update-dknn-skills
description: Check, download, install, and update skills from public dknn/skills-* GitHub repositories, preserving installed version choices and local modifications. Use when asked to update or install dknn skills.
---

# Update dknn skills

Run the bundled `scripts/Update-DknnSkill.ps1` with PowerShell 7. An invocation
asking to update authorizes the normal current-user update. A request only to
check uses `-List`; `-WhatIf` previews the planned writes. Report result rows
and failures, including successful installations when another repository fails.

The default scans existing `.agents` and `.codex` installations, honors
`CODEX_HOME`, and installs new skills in the current Codex root. For another
agent, pass its explicit profile root with `-TargetRoot`. An explicit root
disables automatic discovery. If copies exist in multiple roots, ask which
root to update; do not delete copies or silently follow directory links.

New installations use Stable releases. Existing update choices persist,
including Latest and pinned versions. To change one repository explicitly:

```powershell
& ./scripts/Update-DknnSkill.ps1 -RepositoryPattern skills-verify-and-refine -Channel Stable
& ./scripts/Update-DknnSkill.ps1 -RepositoryPattern skills-verify-and-refine -Channel Latest
& ./scripts/Update-DknnSkill.ps1 -RepositoryPattern skills-verify-and-refine -ExactVersion v1.0.0
```

Resolve script paths relative to this skill's directory, not the current project.
Do not silently opt into `-AllowMajorUpgrade`, `-AllowDowngrade`, or
`-RemoveExtraFiles`; these need an explicit user choice for the affected scope.
Missing stable releases do not authorize falling back to main. Local changes
are conflicts: explain them and preserve the files.

For Windows users explicitly requesting another profile, list profiles with
`scripts/Get-AgentSkillUserProfile.ps1`, then pass selected `-UserSid` values or
use `-SelectUser` in an interactive terminal. Writing another profile requires
an elevated session. Do not collect passwords or use runas. Never select all
machine users by default.

The wrapper snapshots the installed updater before execution, allowing it to
update itself. Execute the installed wrapper, never installation hooks from
downloaded archives. Report that a new agent session may be needed to discover
new skills; do not claim their instructions have replaced an already loaded skill.
