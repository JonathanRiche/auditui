# ADR-002: NDJSON RPC over stdio

- Status: accepted
- Date: 2026-09-02

## Decision

Use versioned newline-delimited JSON over the engine child's stdin/stdout.
Requests have opaque IDs; responses correlate by ID; events can interleave.

## Consequences

Framing is inspectable, streamable, and available in Zig and TypeScript without
a generated RPC stack. Payload schemas and limits are required. Stdout becomes
protocol-only and binary data travels by safe filesystem reference, not inline.
