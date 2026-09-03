# audible-cli compatibility

The target is the pinned `audible-cli` 0.6.0 behavior documented in
[upstream-baseline.md](upstream-baseline.md). The authoritative machine-readable
inventory is [compatibility-manifest.json](compatibility-manifest.json).

Statuses mean:

- `unimplemented`: command/behavior is absent or only a protocol placeholder.
- `partial`: useful behavior exists but a listed option, default, output, prompt,
  auth/config interaction, or exit behavior is not yet compatible.
- `compatible`: differential offline tests and any required opt-in safe live test
  pass against the frozen baseline.
- `intentional-deviation`: incompatibility is documented with rationale and test.

The 2026-09-03 audit contains no `unimplemented` or `partial` entries. This does
not mean drop-in parity: only auth-file serialization is marked `compatible`.
Every human command is an `intentional-deviation` with the exact implemented
surface, omitted baseline semantics, rationale, and verification recorded in
the manifest. Internal RPC methods never affect this score.

## Native compatibility policy

The Zig CLI preserves the useful offline and authenticated workflows while
choosing a smaller, safer contract:

- Secrets are never accepted through argv, environment variables, or ordinary
  stdin. Password-related Python flags are replaced by hidden controlling-TTY
  prompts.
- Cached library list/export is separated from explicit network refresh.
  Network pagination and retry policy are not disguised as list flags.
- Downloads are durable background AAXC jobs managed by the application. The
  synchronous Python progress UI, legacy AAX mode, filename templates, and
  podcast expansion switches are not emulated.
- Wishlist mutation requires exact ASINs plus explicit confirmation. Ambiguous
  title selection is not allowed.
- Profile removal is local-only. Remote deregistration is not coupled to file
  deletion, and the Python `manage auth-file remove` operation fails closed.
- Nested Click help is consolidated into one discoverable root help screen;
  usage and runtime errors share native exit status 1.

These are product and security boundaries, not a promise that unsupported
flags are silently honored. The compatibility test suite explicitly exercises
the fail-closed and consolidated-help behavior.

## Differential review

Run both executables with isolated config/data/state/cache directories and a
fixed terminal width/locale. Compare exit status, stdout, stderr, generated file
names/content, and post-run filesystem state. Normalize only documented values
such as executable name, temporary root, elapsed time, progress redraws, and
upstream version string. `--help` tests are offline. API/library/download tests
are separately opt-in, sanitized, and restricted to safe operations.

Never automate `wishlist add/remove`, `manage auth-file remove` (which remotely
deregisters), or arbitrary mutating `api` methods against a personal account.
Test their request construction against mocks and require manual review for live
use. Plugin commands are an extension mechanism, not part of the built-in 0.6.0
baseline.

## Release gate

Version 1 is not advertised as a drop-in `audible-cli` replacement. Every move
from `intentional-deviation` to `compatible` requires an offline differential
test and, where network behavior matters, a named opt-in test. A new baseline
command starts as `unimplemented`; release automation rejects stale manifest
status rather than allowing missing behavior to look compatible.
