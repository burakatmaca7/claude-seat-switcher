# Security policy

This app handles Claude sign-in credentials, so security reports are taken seriously.

**Please do not open a public issue for a vulnerability.** Use GitHub's
[private vulnerability reporting](../../security/advisories/new) instead.

## What is in scope

- Credentials leaving the Keychain, or being sent anywhere other than Anthropic's endpoints
- Credentials or personal data written to logs, caches or crash reports
- History sync deleting, overwriting or corrupting session files
- Any network call not listed in the networking module

## Commitments

- No server, telemetry or analytics — ever.
- All network calls are defined in one module and listed in the README.
- Every commit and pull request is scanned for secrets.
