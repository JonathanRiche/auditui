# Auditui: Zig engine and OpenTUI client

## 1. Goal

Build a terminal audiobook application with two deliberately separate parts:

1. A native Zig executable that ports the Python `audible-cli` feature set with command-line and behavioral compatibility: profiles, authentication, library access, wishlist operations, downloads, metadata, activation bytes, API requests, configuration management, and output modes.
2. A TypeScript/Bun interface built with OpenTUI Core that presents the library and controls downloads and playback.

The application should let a user authenticate, browse and search their owned Audible library, download books, play local downloads through `mpv`, navigate chapters, and reliably resume playback.

This is intentionally a functionality-complete port, not merely a new client inspired by the Python application. The Python `audible-cli` and its `audible` dependency are the behavioral references. Preserve their useful command hierarchy, flags, defaults, profile/config semantics, auth-file interoperability, download behavior, and user-visible error cases unless a documented Zig-specific deviation is necessary.

Because the upstream projects use the GNU Affero General Public License, treat the Zig port as derivative work and license/distribute it compatibly. Preserve required copyright and license notices, identify the upstream projects, document modifications, and make corresponding source available wherever the AGPL requires it. Perform a license review before the first distributed build. “Verbatim functionality” means compatibility of behavior; do not mechanically transliterate poor implementation details when Zig can provide the same observable behavior more safely.

## 2. Important architectural decision

OpenTUI is implemented internally in Zig, but its supported application APIs are TypeScript, React, and Solid. Therefore, this project is not one all-Zig process.

```text
audible-tui (TypeScript + Bun + OpenTUI Core)
          |
          | versioned JSON messages over stdio
          v
audible-zig (native Zig executable)
          |
          +-- Audible HTTP APIs
          +-- auth/profile storage
          +-- download manager
          +-- SQLite state
          +-- mpv JSON IPC adapter (optional daemon mode)
```

The boundary is intentional. The Zig executable must remain useful without the TUI, and the TUI must not parse human-oriented CLI output.

## 2.1 Upstream references and compatibility baseline

Use these repositories as the primary source references for the port:

- Python CLI: <https://github.com/mkb79/audible-cli>
- Python Audible API library: <https://github.com/mkb79/audible>

At project kickoff, record immutable commit SHAs for both repositories in `docs/upstream-baseline.md`. The locally installed reference versions at the time this plan was written are `audible-cli 0.6.0` and `audible 0.12.0`; verify versions and commits again before freezing the baseline. Review both repositories because much of the CLI's authentication and API behavior lives in the separate `audible` package.

Keep upstream source in a disposable/reference location or as explicitly documented Git submodules; do not silently vendor snapshots without their licenses and notices. Maintain an attribution file and preserve the AGPL licensing chain for the port.

## 2.2 Authorized local test account

This development machine currently has an authenticated Audible profile under `~/.audible/`, including `config.toml` and `Jonathan.json`. The user has authorized agents working on this project to use that existing authenticated profile for implementation and testing, subject to all of these limits:

- Allowed: authentication-status checks, token refresh required for an allowed request, read-only library/metadata/API requests, export comparisons, and download/playback tests for titles already owned by the account.
- Allowed: copy an auth file into a private temporary test directory when required for a compatibility test, provided the copy is deleted afterward and is never printed, logged, committed, or included in fixtures.
- Not allowed without fresh explicit permission: purchases, credit use, wishlist mutations, account/profile changes on Audible, device deregistration, deleting cloud data, changing credentials, or any other externally consequential account mutation.
- Never expose tokens, cookies, device private keys, activation material, voucher keys, passwords, signed URLs, or auth-file contents in terminal output, agent messages, test snapshots, logs, diffs, or commits.
- Live tests must be opt-in and clearly separated from offline/default tests. Prefer read-only calls and the smallest possible owned-title sample.
- Do not assume this authorization applies on another machine, in CI, or to another contributor.

Before the first live test, correct and verify credential permissions. At the time this plan was written, both local files were mode `0644`; they must be restricted to `0600`, and the containing directory should be accessible only to the user. Tests should fail closed when credential permissions are unsafe rather than reading the files.

## 3. Product boundaries

### In scope for version 1

- Compatibility with the complete command surface of the selected Python `audible-cli` baseline release.
- A checked-in compatibility manifest mapping every upstream command, option, default, exit behavior, and output mode to its Zig implementation and tests.
- Canadian Audible marketplace first (`ca`), with locale definitions designed for extension.
- Amazon/Audible authentication and refreshable sessions.
- Multiple named profiles.
- Library listing, pagination, search, filtering, and JSON export.
- Wishlist listing, export, add, and remove behavior matching the Python CLI.
- AAX and AAXC downloads for titles owned by the authenticated account.
- Cover, PDF, chapter, and annotation metadata downloads where available.
- Resumable and atomic downloads.
- Local library index and download status.
- Playback through an installed `mpv` process.
- Play/pause, seek, chapter navigation, volume, speed, and resume position.
- Keyboard-first OpenTUI interface with usable narrow-terminal behavior.
- Structured logs with secrets removed.

### Explicitly out of scope for version 1

- Purchasing titles or spending credits.
- Circumventing access controls for content the account does not own.
- Cloud synchronization of local application state.
- Mobile support.
- A public plugin system.
- Replacing `mpv` with a custom audio decoder.
- Compatibility with releases older or newer than the explicitly pinned Python baseline; later upstream changes are handled through planned parity updates.

## 4. Repository layout

Use a monorepo so the protocol and integration tests evolve together.

```text
audible-tui/
├── README.md
├── LICENSE
├── plan.md
├── justfile
├── docs/
│   ├── architecture.md
│   ├── authentication.md
│   ├── protocol.md
│   └── threat-model.md
├── protocol/
│   ├── schema/
│   ├── fixtures/
│   └── VERSION
├── engine/
│   ├── build.zig
│   ├── build.zig.zon
│   ├── src/
│   │   ├── main.zig
│   │   ├── cli/
│   │   ├── auth/
│   │   ├── api/
│   │   ├── downloads/
│   │   ├── storage/
│   │   ├── player/
│   │   └── protocol/
│   └── tests/
├── tui/
│   ├── package.json
│   ├── bun.lock
│   ├── tsconfig.json
│   ├── src/
│   │   ├── main.ts
│   │   ├── app/
│   │   ├── screens/
│   │   ├── components/
│   │   ├── engine/
│   │   └── theme/
│   └── tests/
└── integration-tests/
```

## 5. Zig engine design

### 5.1 Command-line interface

Pin a specific upstream Python `audible-cli` release as the compatibility baseline. The Zig binary should be installable as `audible` when used as a replacement, while development builds may use `audible-zig` to permit side-by-side differential testing. Preserve the upstream human CLI; add machine-facing functionality without breaking compatible invocations.

The baseline command groups include:

```text
audible activation-bytes
audible api
audible download
audible library list|export
audible wishlist list|export|add|remove
audible manage auth-file ...
audible manage config ...
audible manage profile ...
audible quickstart
```

Inventory the full nested command/option tree from the pinned release rather than treating the abbreviated list above as complete. Match global options such as profile selection, auth-file password handling, verbosity, logging, version, and help. Match command aliases, accepted value forms, prompts, confirmation behavior, defaults, output files, and exit statuses where scripts may depend on them.

Additional Zig/TUI integration commands should live in a reserved namespace so they cannot collide with upstream parity:

```text
audible internal rpc
audible internal health
```

The internal namespace is not part of Python compatibility. Its exit codes and error objects must be documented and stable. Human diagnostics go to stderr; structured protocol results go to stdout.

### 5.2 Compatibility program

Create `docs/compatibility.md` and a machine-readable manifest that tracks every feature in the pinned Python release. Each entry should be one of `unimplemented`, `partial`, `compatible`, or `intentional-deviation`, with a test or explanation linked from it.

Compatibility includes more than matching command names:

- Help hierarchy, option names, short flags, accepted values, and defaults.
- Interactive quickstart and management prompts.
- Profile selection and case-sensitivity behavior.
- Existing `config.toml` and auth JSON discovery/loading behavior.
- Library, wishlist, API, download, and activation-byte semantics.
- Filename modes and length handling.
- Date filtering, pagination, timeouts, parallel jobs, confirmation, overwrite, and error-continuation behavior.
- AAX/AAXC media, voucher, PDF, cover, chapters, and annotations.
- TSV, CSV, JSON, terminal output, log levels, and exit status behavior.

Use a differential harness that runs the same safe invocation against Python and Zig with isolated temporary config/data directories, normalizes nondeterministic fields, and compares results. Use a dedicated account and non-destructive requests for live comparisons. Never run purchasing, deletion, deregistration, or other consequential operations automatically.

Snapshot upstream `--help` output and construct synthetic fixtures for offline parity tests. Network response fixtures must be sanitized. Add a documented review process for rebasing the compatibility baseline to a later Python release.

### 5.3 TUI protocol

The TUI should launch `audible internal rpc` as a long-lived child process. Communication uses newline-delimited JSON over stdin/stdout.

Request:

```json
{"v":1,"id":"42","method":"library.list","params":{"profile":"Jonathan"}}
```

Response:

```json
{"v":1,"id":"42","ok":true,"result":{"items":[],"nextCursor":null}}
```

Asynchronous event:

```json
{"v":1,"event":"download.progress","data":{"jobId":"abc","received":1048576,"total":734003200}}
```

Protocol requirements:

- Monotonically version the protocol.
- Correlate requests with opaque IDs.
- Permit interleaved progress and player events.
- Define cancellation for long-running requests.
- Never place tokens, cookies, passwords, private keys, or voucher secrets in events.
- Put JSON schemas and representative fixtures under `protocol/`.
- Add contract tests that run against both the Zig server and TypeScript client.

### 5.4 Authentication

Authentication is the highest-risk portion and should be implemented before downloads.

Research and document the currently observed login and token-refresh flow before coding it. Prefer an external-browser login so the application never directly handles an Amazon password. Support MFA/CAPTCHA through the browser rather than attempting to reproduce those forms in the terminal.

Requirements:

- Register only the minimum device/session information required by Audible.
- Persist refreshable credentials with strict file permissions (`0600`).
- Use the OS keyring when practical, with an encrypted-file fallback.
- Never accept auth secrets as ordinary command-line arguments because process lists and shell history can expose them.
- Redact authorization headers, cookies, tokens, device keys, voucher keys, and signed URLs from logs.
- Refresh access tokens automatically and write updated credentials atomically.
- Provide explicit logout/revoke behavior.
- Design a one-time importer for existing `~/.audible/*.json` profiles, but do not modify the originals.

Do not promise authentication compatibility until tested against a dedicated test account. Audible endpoints are not a stable public API and can change without notice.

### 5.5 API layer

Create a typed API client rather than spreading endpoint knowledge throughout commands.

Responsibilities:

- Marketplace/locale discovery and endpoint selection.
- Required headers, device identity, signing, and authorization.
- Token refresh and one safe retry after authorization failure.
- Pagination and rate-limit handling.
- Bounded retries with exponential backoff and jitter.
- Request timeouts and cancellation.
- Typed parsing with preservation of unknown fields where useful.
- Sanitized HTTP diagnostics.

Start with library listing. Capture sanitized response fixtures for offline tests. Add wishlist and metadata endpoints only after the library client is stable.

### 5.6 Downloads

The download manager should support:

- Selection by ASIN, exact ID, or title search result.
- AAX and AAXC media plus the AAXC voucher where required.
- Optional cover, PDF, chapters, and annotations.
- `.part` files and atomic rename on completion.
- HTTP range requests and resumable downloads when the server permits them.
- Content length/checksum validation where metadata is available.
- Bounded parallelism and cancellation.
- Stable, sanitized filenames and configurable output templates.
- A persistent job table so interrupted jobs can recover after restart.

Never overwrite an existing completed file unless the user explicitly requests it.

### 5.7 Storage

Use SQLite for application state, with schema migrations committed to the repository.

Suggested tables:

- `profiles` (non-secret profile metadata only)
- `library_items`
- `local_files`
- `download_jobs`
- `playback_positions`
- `bookmarks`
- `settings`
- `schema_migrations`

Keep credential material outside the general database unless it is encrypted with a key stored separately. Use transactions and prepared statements. Enable WAL only after checking behavior on the supported filesystems.

Default locations should follow XDG conventions:

```text
$XDG_CONFIG_HOME/audible-tui/
$XDG_DATA_HOME/audible-tui/
$XDG_STATE_HOME/audible-tui/
$XDG_CACHE_HOME/audible-tui/
```

### 5.8 Playback

Use `mpv` as the media engine. Do not implement decoding in Zig.

Launch `mpv` with a private JSON IPC socket and a deliberately constructed argument list. Never build a shell command from filenames. Subscribe to time position, duration, pause state, chapter, speed, and end-of-file events.

Playback requirements:

- Start and stop cleanly.
- Pause/resume and relative/absolute seek.
- Chapter navigation.
- Playback speed and volume.
- Persist position periodically and on clean shutdown.
- Resume conservatively, resetting near the true end of a completed title.
- Detect missing `mpv` and unsupported media with actionable errors.
- Keep any activation or voucher material out of process arguments when an IPC/property/file-descriptor alternative exists.

The exact AAX/AAXC playback path must be proven in a focused technical spike before committing the rest of the player architecture. Test with content owned by the authenticated account. If direct playback is unreliable, version 1 may explicitly require a user-managed playable local copy while download support matures.

## 6. OpenTUI application design

Use TypeScript, Bun, and `@opentui/core` directly. Avoid React/Solid initially unless state complexity demonstrates a clear need. Pin exact dependency versions.

### Visual direction

The product should feel like a terminal interpretation of the Audible web library and player, not a developer-oriented table of API records. Book artwork is the main navigation language.

The default home/library screen should show:

- A cover-art grid resembling Audible's browser library.
- Continue-listening titles first, followed by downloaded and full-library sections.
- Audible-style information hierarchy: cover, title, author/narrator, duration/progress, and download state.
- A clearly highlighted selected cover with its essential metadata nearby.
- A persistent player dock showing the cover and controls for the book currently playing.

When the terminal supports an image protocol, render real cover artwork using OpenTUI's image capabilities. Detect support rather than assuming it. Cache resized covers locally and avoid fetching or decoding images during a render pass. Provide a deliberate fallback for unsupported terminals: a colored cover-shaped tile containing a shortened title/author, not an empty placeholder or raw URL.

The visual system should borrow the useful concepts users recognize from Audible without copying proprietary assets or attempting pixel-for-pixel reproduction:

- Dark, warm, content-focused palette.
- Cover art as the strongest visual element.
- Orange/gold accent for active controls and progress.
- Restrained borders and chrome.
- Clear typography and spacing despite terminal-cell constraints.
- Playback progress visible both on the selected book and in the player dock.

The interface must still be usable with monochrome output and with images disabled. Color and artwork enhance meaning but cannot be the only representation of state.

### Core layout

Large terminals should use a visual library with an inspector and player dock:

```text
┌ Audible ─ Library ─ Downloads ─ Wishlist ───────────── Search ┐
│                                                              │
│ Continue listening                                           │
│ ┌─────────┐ ┌─────────┐ ┌─────────┐                          │
│ │  COVER  │ │  COVER  │ │  COVER  │                          │
│ │         │ │         │ │         │                          │
│ └─────────┘ └─────────┘ └─────────┘                          │
│ Dune        Leviathan    Project Hail Mary                   │
│ █████░ 32%  Downloaded   █████████░ 81%                      │
│                                                              │
│ Your library                                                 │
│ ┌─────────┐ ┌─────────┐ ┌─────────┐ ┌─────────┐              │
│ │  COVER  │ │  COVER  │ │  COVER  │ │  COVER  │              │
│ └─────────┘ └─────────┘ └─────────┘ └─────────┘              │
├──────────────────────────────────────────────────────────────┤
│ [cover] Dune · Chapter 12                                    │
│   ◀◀   ▶/❚❚   ▶▶    06:42:18 ━━━━━━━━━━━━ 21:03:45   1.2×   │
└──────────────────────────────────────────────────────────────┘
```

Selecting a book should open or expand a detail view containing a larger cover, description, author, narrator, runtime, release information, listening progress, download state, and chapter list. The primary actions should be Resume/Play and Download, not low-level format choices.

On narrow terminals, collapse the cover grid to a single-column visual shelf and reduce the player dock to cover/title, play state, progress, and elapsed time. Full controls remain available on the now-playing screen and through shortcuts.

### Player experience

The currently playing book must remain visible throughout the application. The persistent player dock should include:

- Small cover image or cover-tile fallback.
- Title and current chapter.
- Play/pause, previous/next chapter, and seek controls.
- Elapsed time, total time, and a seekable progress bar.
- Playback speed, volume, and sleep-timer state.
- Download/buffering/error state when relevant.

The full now-playing screen should prioritize a large cover and transport controls, then show chapter navigation, queue information, bookmarks, and book details. Controls should update immediately from `mpv` events instead of optimistically drifting from real playback state.

Add these player behaviors to the version 1 design:

- Resume from the saved position.
- Seek by keyboard and mouse where supported.
- Jump between chapters.
- Change playback speed without changing pitch.
- Add a local bookmark at the current timestamp.
- Start a sleep timer by duration or end of chapter.
- Display a clear ended/completed state.
- Continue playing while the user browses other screens.

### Primary screens

1. **Onboarding** — engine discovery, `mpv` check, profile import/create, browser authentication.
2. **Home/library** — cover grid, continue-listening shelf, downloads, full library, search, and filtering.
3. **Book detail** — large cover, Audible-style metadata, description, progress, chapters, files, download actions, and resume action.
4. **Downloads** — queued/active/completed/failed jobs with progress and retry/cancel actions.
5. **Now playing** — large cover, timeline, chapter list, speed, volume, sleep timer, bookmarks, and transport controls.
6. **Wishlist** — read-only initially; mutations after API stabilization.
7. **Settings/profiles** — paths, marketplace, profiles, key bindings, and diagnostics.

### Interaction principles

- Keyboard-first, with mouse as a convenience.
- A command palette for discoverability.
- Vim-style navigation as an optional mapping, not the only mapping.
- Global `?` help overlay displaying context-sensitive shortcuts.
- Clear focus indication and no color-only state distinctions.
- Graceful layouts at 80x24; enhanced layouts for larger terminals.
- Reduced-motion mode and terminal color capability detection.
- Never block rendering while the engine performs network or disk work.
- Preserve playback and the player dock across screen transitions.
- Virtualize large cover grids so library size does not degrade input responsiveness.
- Reserve layout space while covers load to prevent visual jumping.

### Default key ideas

```text
q            quit/back (with confirmation for active work)
?            help
/            search
j/k or arrows move selection
Enter        open/activate
Space        play/pause
h/l          seek backward/forward
[/]          previous/next chapter
d            download
c            cancel selected download
,/.          decrease/increase speed
```

Finalize bindings only after a small usability pass; avoid binding destructive actions to a single unconfirmed key.

## 7. Security and privacy requirements

- Add a threat model before authentication is considered complete.
- Set restrictive permissions on configuration and credential directories.
- Use atomic writes for secrets and state.
- Do not collect telemetry by default.
- Ensure crash reports and debug bundles redact secrets and signed URLs.
- Never print full API responses without a deliberate unsafe-development flag.
- Exclude auth files, databases, downloads, fixtures captured from real accounts, and debug logs in `.gitignore`.
- Use synthetic or aggressively sanitized fixtures in the repository.
- Document that users must comply with Audible terms and applicable law and should only access content associated with their accounts.

## 8. Testing strategy

### Zig unit tests

- JSON parsing and forward-compatible unknown fields.
- Locale/marketplace mapping.
- Filename sanitization.
- Pagination, retries, and backoff using a local mock HTTP server.
- Atomic writes and interrupted-download recovery.
- Database migrations and playback-position rules.
- Secret redaction.

### TUI tests

- Reducer/state-transition tests independent of rendering.
- Engine-client protocol parsing and cancellation.
- Snapshot tests for important layouts at several terminal sizes.
- Keyboard navigation and focus behavior.
- Engine death/restart and malformed-event handling.

### Integration tests

- Spawn the real Zig RPC process from Bun and exercise protocol fixtures.
- Run downloads against a controllable local HTTP server with range support, failures, delays, and truncation.
- Run an `mpv` IPC smoke test with a generated public-domain audio fixture.
- Keep live Audible tests opt-in and outside normal CI; never use personal credentials in CI.

### Quality gates

- `zig fmt` and all Zig tests pass.
- TypeScript type checking, formatting, linting, and tests pass.
- No secrets detected in the repository or test output.
- Protocol compatibility tests pass.
- Manual smoke tests pass in at least two terminal emulators and at 80x24.

## 9. Delivery phases

### Phase 0: feasibility spikes

Before building the full application, prove the risky assumptions:

1. Make an authenticated library request from a minimal Zig program.
2. Refresh an expired access token and safely persist the result.
3. Import a copy of an existing auth profile without exposing its contents.
4. Download one owned test title and associated metadata.
5. Play representative AAX and AAXC files through `mpv`, including seeking.
6. Run a minimal OpenTUI app that exchanges concurrent JSON events with a Zig child process.

Deliverable: a written feasibility report with decisions, known fragility, and sanitized fixtures. Stop and revise the architecture if authentication or playback cannot be made reliable.

### Phase 1: repository and protocol foundation

- Scaffold Zig and Bun packages.
- Add formatting, linting, tests, and CI.
- Define protocol version 1 schemas, fixtures, and error taxonomy.
- Implement RPC lifecycle, cancellation, logging, and graceful shutdown.
- Add XDG path resolution and SQLite migrations.

Acceptance: the OpenTUI test shell can start the engine, request its version/health, receive events, cancel work, and recover from an engine crash.

### Phase 2: profiles and authentication

- Implement secure credential storage abstraction.
- Add profile CRUD and default selection.
- Implement external-browser authentication, refresh, status, and logout.
- Add non-destructive import of existing auth JSON.
- Document recovery from expired/revoked credentials.

Acceptance: a fresh user can authenticate, restart the program, refresh silently, and log out; logs and debug output contain no secrets.

### Phase 3: library and wishlist

- Implement typed library models, pagination, caching, and refresh.
- Add list/search/filter/export commands.
- Implement wishlist list/export.
- Build onboarding, library, book-detail, and profile screens.

Acceptance: the TUI remains responsive while loading a large library and can work from cached metadata when offline.

### Phase 4: downloads

- Implement job persistence, range resume, progress events, cancellation, and validation.
- Add media, voucher, cover, PDF, chapter, and annotation handling.
- Build downloads screen and book download actions.

Acceptance: interrupted downloads resume without corrupting completed files, concurrent jobs remain bounded, and failures are actionable.

### Phase 5: playback

- Implement `mpv` process and JSON IPC supervision.
- Add transport, seeking, chapters, speed, volume, and end-of-file handling.
- Persist and restore position.
- Build now-playing bar and full player screen.

Acceptance: a user can play, pause, seek, change chapter/speed, restart the app, and resume within a small tolerance of the saved position.

### Phase 6: hardening and packaging

- Test terminal sizes, colors, mouse behavior, signals, suspend/resume, and shutdown.
- Improve accessibility and error recovery.
- Add upgrade/migration tests.
- Produce checksummed Zig engine binaries and a documented Bun/OpenTUI installation path.
- Investigate a compiled Bun frontend only after validating OpenTUI native dependency packaging on each target.

Acceptance: clean installation on a new supported Linux machine with only documented runtime dependencies; no hidden dependency on the Python `audible-cli` remains.

## 10. Migration strategy

During development, the Python `audible-cli` may serve as a behavioral reference and temporary fallback, but removal is a milestone:

1. Use it to establish sanitized expected outputs and validate account behavior.
2. Implement and compare Zig library/auth operations.
3. Implement and compare downloads and metadata.
4. Disable the fallback in normal builds.
5. Run end-to-end tests with no Python environment or `audible` executable available.

Version 1 is not complete if ordinary operation still shells out to Python `audible-cli`.

## 11. Initial technical decisions to record as ADRs

- ADR-001: Zig engine plus TypeScript/OpenTUI process boundary.
- ADR-002: newline-delimited JSON RPC over stdio.
- ADR-003: SQLite for durable non-secret state.
- ADR-004: credential backend and encrypted fallback.
- ADR-005: `mpv` as the playback engine.
- ADR-006: clean-room behavior study and licensing policy.
- ADR-007: supported marketplaces and compatibility expectations.

## 12. Definition of version 1 complete

Version 1 is complete when a new user on a supported Linux system can:

1. Install the Zig engine and OpenTUI client using documented steps.
2. Authenticate without giving an Amazon password to the terminal application.
3. Browse and search their owned Audible library.
4. Download a supported title with visible, cancellable progress.
5. Play it through `mpv`, navigate chapters, change speed, and resume later.
6. Recover safely from network failure, engine restart, and interrupted download.
7. Use the core engine from scripts through documented JSON commands without launching the TUI.

The release must also pass the security, protocol, and clean-machine installation checks above, and normal operation must not depend on the Python implementation.

## 13. First implementation task

Do not begin with visual polish. Begin with Phase 0 and create a disposable spike that proves one authenticated library request, one token refresh, and representative AAX/AAXC playback. Those findings determine the real API, credential, and media abstractions; designing them before the spike would create avoidable rework.
