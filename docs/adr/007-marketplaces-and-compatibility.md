# ADR-007: Canada-first, frozen compatibility baseline

- Status: accepted
- Date: 2026-09-02

## Decision

Ship Canada (`ca`) first while modeling the upstream marketplace codes `de`,
`us`, `uk`, `fr`, `ca`, `it`, `au`, `in`, `jp`, `es`, and `br`. Target only
the immutable versions in `docs/upstream-baseline.md`.

## Consequences

Non-Canadian locales can be represented without claiming they are tested.
Upstream changes do not silently redefine compatibility; updating the baseline
requires a manifest diff, tests, and explicit review.
