# ADR-003: SQLite for durable non-secret state

- Status: accepted
- Date: 2026-09-02

## Decision

Store library cache, local files, download jobs, playback positions, bookmarks,
settings, and schema migrations in SQLite. Keep credential material elsewhere.

## Consequences

Transactions make job and resume recovery tractable and migrations are explicit.
The project gains a native dependency and must test filesystem/WAL behavior.
Tokens, cookies, keys, activation bytes, and vouchers are prohibited columns.
