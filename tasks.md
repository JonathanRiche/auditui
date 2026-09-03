# Auditui version 1 completion

This checklist is the working completion contract derived from `plan.md` and
the 2026-09-03 implementation audit. A checked item requires implementation,
tests, and user-facing documentation; a schema or UI label alone does not count.

## P0 — behavior the current UI already promises

- [x] Persist playback position periodically and on shutdown; resume it on the
      next launch and reset conservatively near completion.
- [x] Make downloads asynchronous with real incremental progress, durable job
      state, restart recovery, bounded concurrency, retry, and cancellation.
- [x] Make encrypted profiles usable from the application without transmitting
      passphrases through RPC, argv, logs, or ordinary stdin.
- [x] Add complete volume, speed, chapter, bookmark, and sleep-timer controls.
- [x] Remove or replace every visible control whose engine operation is a stub.

## P1 — complete product screens

- [x] Add onboarding and account/profile connection, status, import, selection,
      logout, and safe local removal flows.
- [x] Add Wishlist list/export/add/remove engine behavior and TUI screen, with
      confirmation for mutations and no automatic live mutation tests.
- [x] Add Settings/Profiles and diagnostics screens.
- [x] Expand Now Playing with cover, chapter list, bookmark management, sleep
      timer, volume, speed, transport controls, queue/error state, and metadata.
- [x] Complete Downloads with queued/active/completed/failed/cancelled states,
      visible progress, retry, cancel, and actionable errors.
- [x] Add metadata artifacts: cover, PDF, chapters, and annotations when Audible
      provides them.
- [x] Add a discoverable command palette and context-complete help.

## P2 — Zig `audible-cli` 0.6.0 compatibility

- [x] Implement and differentially test global help/options/output/exit behavior.
- [x] Implement `activation-bytes`.
- [x] Implement the generic `api` command with safe method handling and redaction.
- [x] Implement the complete human `download` command and its selection, format,
      output-template, overwrite, pagination, timeout, and metadata options.
- [x] Complete `library list` and `library export` formats and filters.
- [x] Implement `wishlist list|export|add|remove`.
- [x] Implement `manage config edit` and compatible config discovery.
- [x] Implement `manage profile add|list|remove`.
- [x] Implement `manage auth-file add|remove|encrypt|decrypt`, preserving safe
      confirmation and never running remote deregistration in automated tests.
- [x] Complete `quickstart` options, prompts, defaults, and exit behavior.
- [x] Move every applicable compatibility-manifest entry to `compatible` or a
      tested/documented `intentional-deviation`.

## P3 — persistence, resilience, and scale

- [x] Use the migrated SQLite tables for profiles, library items, local files,
      download jobs, playback positions, bookmarks, and settings.
- [x] Keep the UI responsive during network/disk work and recover from engine
      restart, malformed events, network failure, and interrupted downloads.
- [x] Virtualize or window large cover grids and preserve keyboard/mouse focus.
- [x] Validate reduced-color/monochrome rendering and 80×24 behavior.
- [x] Keep cover loading asynchronous, cached, and layout-stable.

## P4 — release hardening

- [x] Update stale feasibility and compatibility documentation with sanitized
      evidence from the proven native auth, library, AAXC download, and playback.
- [x] Add TypeScript formatting/linting and repository secret scanning gates.
- [x] Add clean-machine installation and upgrade/migration tests.
- [x] Test current Ghostty plus a second terminal and safe block-image mode.
- [x] Provide a documented install/package path and checksummed release artifacts.
- [x] Perform and record the pre-distribution AGPL/license review.
- [x] Run the complete offline gate, RPC/download/mpv E2E tests, opt-in safe live
      account checks, and manual Ghostty acceptance pass.

## Definition of done

- [x] A fresh user can install, authenticate, browse/search, download with
      cancellable progress, play, navigate chapters, change volume/speed, bookmark,
      use a sleep timer, quit, restart, and resume without Python dependencies.
- [x] Every visible action works, errors are actionable, secrets remain redacted,
      and ordinary operation never requires undocumented commands.
- [x] `mise run test`, `mise run rpc:e2e`, packaging checks, and manual acceptance
      tests pass from a clean supported environment.

## Completion evidence

- `mise run release:check` passed on 2026-09-03, including the complete offline
  suite, durable download cancellation/retry, real mpv IPC, 80×24 terminal,
  clean-install, migration, package-install, secret, and license gates.
- Live Ghostty acceptance used the authorized Audible Canada profile: four owned
  titles refreshed, native covers rendered, two completed downloads survived a
  relaunch, and resume, timing, transport, and chapter selection worked.
- The Python 0.6.0 compatibility surface has 30 release-classified entries. Safe
  native behavior is tested; deliberate differences such as the durable AAXC
  manager and refusal to accept passwords on argv are documented in
  `docs/compatibility.md` and `docs/compatibility-manifest.json`.
- Release artifact SHA-256:
  `dcc616ee703e0c65cd051b9924934f81eed9fa036fe531b2bd0034e75310a688`.
