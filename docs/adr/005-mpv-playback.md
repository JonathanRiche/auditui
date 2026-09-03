# ADR-005: mpv as playback engine

- Status: accepted provisionally
- Date: 2026-09-02

## Decision

Supervise an installed mpv process using a private JSON IPC endpoint. Do not
implement an audio decoder in Zig.

## Consequences

The application inherits mpv's codec/platform coverage and can observe actual
position, pause, chapter, speed, and end events. mpv is a documented runtime
dependency. Direct AAX/AAXC playback remains a feasibility gate; a user-managed
playable-copy requirement may be necessary if representative tests fail.
