---
applyTo: "tests/**/*.ps1"
---

# Test instructions

- Keep tests dependency-free and runnable with `pwsh -NoProfile -File`.
- Create fixtures only in a uniquely named directory under the operating
  system's temporary directory.
- Verify the cleanup target before recursively deleting it.
- Test successful copying, ignored non-skill files, stale-file cleanup, and
  isolation from other installed skills.
- Fail with explicit messages that identify the unmet expectation.
- Use `scripts/Invoke-Validation.ps1` as the complete local and CI quality
  gate.
