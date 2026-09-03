# ADR-004: Keyring-first credential storage

- Status: accepted with implementation spike required
- Date: 2026-09-02

## Decision

Prefer an OS Secret Service/keyring backend. Offer an authenticated encrypted
file fallback with TTY/file-descriptor passphrase input. Import upstream files
non-destructively and require `0700` directories and `0600` files.

## Consequences

Headless systems remain supported but may prompt once per launch. Keyring and
file backends need the same atomic-update interface. Ordinary argv and environment
variables are not accepted for new secret entry, an intentional security
deviation from upstream password options.
