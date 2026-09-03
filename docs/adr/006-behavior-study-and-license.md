# ADR-006: Behavioral port and AGPL policy

- Status: accepted
- Date: 2026-09-02

## Decision

Study the immutable upstream releases, reproduce observable behavior with new
Zig/TypeScript implementation, preserve attribution, and distribute the whole
combined project under AGPL-3.0-only. Do not vendor upstream source or assets.

## Consequences

The compatibility manifest and differential tests become release artifacts.
Modified-source offers and network-use source availability must cover the full
corresponding source. A human license review is required before distribution;
this ADR is engineering policy, not legal advice.
