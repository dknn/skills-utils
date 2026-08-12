---
applyTo: "**/*.ps1"
---

# PowerShell instructions

- Target PowerShell 7 or newer on Windows, macOS, and Linux.
- Use `[CmdletBinding()]`, strict mode, terminating errors, and descriptive
  parameter validation in executable scripts.
- Prefer `Join-Path`, `Resolve-Path`, and `-LiteralPath` over manually composed
  paths.
- Never assume a particular username, drive letter, home directory, or
  repository checkout location.
- Restrict deletion to an explicitly selected target and test that it cannot
  affect sibling skills or the actual user profile.
- Keep console output short and include the resolved destination when copying.
- Validate syntax and run the focused tests after changes.
