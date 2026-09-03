# Licensing and distribution checklist

The project is licensed `AGPL-3.0-only`; the complete license is at `LICENSE`.
`NOTICE` attributes the two AGPL upstream behavioral references and identifies
the major modifications. The frozen upstream files declare the same license.

Before any distributed build or hosted/network-accessible deployment:

1. Confirm every dependency's license, including Zig packages, Bun packages,
   bundled fonts/assets, SQLite linkage, and packaging tools. Record generated
   third-party notices and source-offer obligations.
2. Include `LICENSE`, `NOTICE`, corresponding source, build/install scripts,
   lockfiles, protocol schemas, and modifications needed to reproduce that exact
   binary. Preserve upstream notices in any actually copied files.
3. Provide users who interact with a modified version over a network a clear,
   working way to obtain its corresponding source as required by AGPL section 13.
4. Keep the source offer/link valid for every shipped binary and verify release
   archives from a clean machine.
5. Do not include upstream logos, real cover art, captured API fixtures, auth
   files, databases, downloads, logs, signed URLs, keys, activation bytes, or
   vouchers.
6. Re-run secret scanning and have a qualified reviewer assess the final product
   and dependency combination. This checklist is not legal advice.

Behavior can be compatible without copying implementation text. Any upstream
code or asset intentionally copied later must retain its authorship/license
header and be listed in `NOTICE` with a precise path and provenance.

## Recorded engineering review — 2026-09-03

- Project license and notices agree on `AGPL-3.0-only`; the README identifier
  was corrected to match the shipped license text.
- No upstream logo, cover, account response, media, or credential is present in
  the release input. `mise run security:secrets` enforces the sensitive-file and
  credential-pattern gate.
- Direct and transitive JavaScript package metadata was reviewed against the
  allowlist by `mise run license:check`; the pinned inventory is summarized in
  `THIRD_PARTY_NOTICES.md`.
- The release archive includes `LICENSE`, `NOTICE`, `README.md`, and
  `THIRD_PARTY_NOTICES.md`. Its checksum, contents, isolated install, and native
  engine startup are exercised by `mise run release:verify`.
- Corresponding source, exact lockfiles, schemas, and build scripts remain the
  preferred distribution companion for every binary archive. A public release
  must link the exact source revision and preserve that link for hosted use.

This is the completed pre-distribution engineering review. It is not a legal
opinion; a distributor remains responsible for counsel and for licenses of
system mpv/SQLite builds in the target distribution.
