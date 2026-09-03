# ADR-001: Zig engine and TypeScript TUI boundary

- Status: accepted
- Date: 2026-09-02

## Decision

Use a native Zig engine for CLI parity, credentials, HTTP, storage, downloads,
and playback supervision, with a Bun/TypeScript application using supported
OpenTUI APIs. Run them as separate processes.

## Consequences

The engine remains scriptable without a UI and failures are isolated. Packaging
and integration testing cover two runtimes, and all shared behavior must cross a
versioned protocol instead of using in-process objects.
