# Repository instructions

This repository provides dependency-free PowerShell utilities for reusable
agent-skill maintenance workflows.

- Follow `AGENTS.md` and applicable scoped instructions under
  `.github/instructions/`.
- Prefer small standalone scripts over modules or abstractions until multiple
  utilities demonstrate a shared need.
- Keep all paths and examples portable and free of user- or machine-specific
  values.
- Do not access the network, install dependencies, or write to a real user
  profile in tests.
- Preserve public parameters unless a contract change is explicitly approved.
- Update README usage and regression tests when behavior changes.
- Run `pwsh -NoProfile -File .\scripts\Invoke-Validation.ps1` before
  completing changes.
