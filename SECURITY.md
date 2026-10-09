# Security policy

This app handles Claude sign-in credentials, so security reports are taken seriously.

**Please do not open a public issue for a vulnerability.** Use GitHub's
[private vulnerability reporting](../../security/advisories/new) instead.

## What is in scope

- Credentials leaving the Keychain, or being sent anywhere other than Anthropic's endpoints
- Credentials or personal data written to logs, caches or crash reports
- History sync deleting, overwriting or corrupting session files
- Any network call not listed in the networking module

## Known, by design

- Claude Code keeps its sign-ins in the login Keychain readable by any process running as the same user
  (via `/usr/bin/security`). This app reads them the same way; it does not widen that access.
- Status-line scripts run as you. They are off by default and only run if owned by you and not writable by others.

## Commitments

- No server, telemetry or analytics — ever.
- All HTTP requests are defined in one module and listed in the README; redirects are refused.
- Release builds are made by GitHub Actions from the tagged source, with a signed build-provenance attestation.
- Every commit and pull request is scanned for secrets.
