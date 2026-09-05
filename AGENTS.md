# AGENTS.md for skills-utils

## Scope

This repository contains small, reusable utilities for maintaining agent skill
repositories. Utilities must remain independent of any specific user profile,
machine, organization, or skill repository.

The optional `skills/update-dknn-skills` adapter may select the public dknn
repositories. Keep its underlying engine generic; regenerate bundled scripts
with `scripts/Build-UpdateSkill.ps1` and verify parity with `-Check`.

## Instruction hierarchy

1. Read this file before making changes.
2. Read `.github/copilot-instructions.md`.
3. Read applicable files under `.github/instructions/`.
4. Follow the existing repository conventions and tests.

If instructions conflict, follow the stricter safety or verification rule.

## Change policy

- Keep each change focused and reviewable.
- Write a concrete plan before changing behavior or repository structure.
- Preserve existing parameters and behavior unless the requested change
  explicitly requires otherwise.
- Do not add dependencies, publishing, packaging, or network access without
  explicit approval.
- Do not introduce machine-specific paths, personal names, email addresses,
  credentials, tokens, or other sensitive data.
- Do not commit generated test output or temporary directories.

## PowerShell conventions

- Target PowerShell 7 or newer and keep scripts cross-platform.
- Use approved PowerShell verbs and descriptive singular nouns for scripts.
- Use `[CmdletBinding()]`, `Set-StrictMode -Version Latest`, and
  `$ErrorActionPreference = "Stop"` in executable scripts.
- Prefer explicit parameter validation and `-LiteralPath` for user-supplied
  paths.
- Use `Copy-Item` for copy operations.
- Throw actionable errors instead of silently continuing.
- Avoid destructive behavior by default. Any cleanup option must be explicit
  and restricted to the selected utility target.
- Keep examples generic and resolve the current user's profile at runtime.

## Testing and verification

- Add or update a focused regression test when script behavior changes.
- Tests must use isolated temporary directories and must never write to the
  real user profile.
- Before completing a PowerShell change, run:

  ```powershell
  pwsh -NoProfile -File .\scripts\Invoke-Validation.ps1
  ```

- The validation entrypoint installs the pinned actionlint release into the
  ignored `.tools` directory, validates workflows, parses every repository
  PowerShell file, and runs the regression tests.
- Also run `git diff --check`.
- Report skipped or failing checks and any unrelated working-tree changes.

## Git safety

- Check `git status` before editing and before finishing.
- Preserve unrelated user changes.
- Do not commit, push, force-push, or rewrite history unless explicitly asked.
- Review the final diff and include only files relevant to the approved task.
