# Security policy

## Reporting a vulnerability

Report vulnerabilities privately through the repository's GitHub Security
Advisories page. Do not publish credentials, personal information, exploit
details, or other sensitive data in a public issue.

Include the affected utility, reproduction steps, expected impact, and any
suggested mitigation. A maintainer can then coordinate validation and a fix
before public disclosure.

## Security expectations

- Utilities must not collect or transmit user data.
- Network access and dependency installation require explicit approval.
- Scripts must not delete files by default.
- Any cleanup operation must be opt-in and restricted to its documented target.
- Tests must never write to or remove files from a real user profile.
- Downloaded development tools must use a pinned version and verified checksum.
- GitHub Actions must use least-privilege permissions and immutable commit-SHA
  references for third-party actions.
