# Contributing

Keep contributions small, portable, and dependency-free.

## Before changing a utility

1. Read `AGENTS.md` and the applicable files under `.github/instructions/`.
2. Check the working tree with `git status`.
3. Describe any behavior or public-parameter change before implementing it.
4. Add or update a focused regression test.

## Verify a change

Run the repository tests from the repository root:

```powershell
pwsh -NoProfile -File .\scripts\Invoke-Validation.ps1
git diff --check
```

Tests must use isolated temporary paths and must not modify the current user's
real `.agents` directory.

The first validation run downloads the pinned actionlint release to the
ignored `.tools` directory and verifies its SHA-256 before execution. Internet
access is therefore required for the first run or after changing the pinned
version. Subsequent runs reuse the verified executable.

## Pull requests

- Explain the problem and the intended behavior.
- Keep unrelated refactoring and formatting out of the change.
- Document tests performed and any checks that could not be run.
- Do not include credentials, personal information, or machine-specific paths.
