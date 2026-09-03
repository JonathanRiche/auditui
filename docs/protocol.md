# Engine protocol version 1

`audible internal rpc` consumes and emits UTF-8 newline-delimited JSON. Each
line is exactly one object. The current version is in `protocol/VERSION`; JSON
Schemas and synthetic fixtures are under `protocol/`.

Requests contain `v: 1`, an opaque non-empty string `id`, a `method`, and an
optional object `params`. Exactly one response echoes every accepted request ID:

```json
{"v":1,"id":"42","method":"library.list","params":{"profile":"example"}}
{"v":1,"id":"42","ok":true,"result":{"items":[],"nextCursor":null}}
```

Failures use `ok: false` and `error: {code,message,details?}`. Version 1 codes:

| Code | Meaning |
|---|---|
| `INVALID_REQUEST` | Invalid JSON, envelope, version, or parameters |
| `METHOD_NOT_FOUND` | Method is outside the version-1 namespace |
| `NOT_IMPLEMENTED` | Reserved method is recognized but unavailable |
| `INTERACTIVE_REQUIRED` | Operation must use the interactive CLI |
| `PASSWORD_REQUIRED` | An encrypted profile needs a TTY passphrase |
| `REAUTH_REQUIRED` | Profile credentials are absent, invalid, or revoked |
| `UNSAFE_CREDENTIALS` | Credential file permissions allow another user access |
| `RATE_LIMITED` | Audible asked the client to retry later |
| `INTERNAL` | Sanitized unexpected engine failure |

`message` is suitable for display, not automation. `details` must be structured,
safe to log, and optional. Stack traces, filesystem credential paths, request
headers, tokens, cookies, keys, vouchers, and signed URLs are forbidden.

## Methods

| Method | Purpose | Cancellation |
|---|---|---|
| `health` | Engine/protocol/dependency health | no |
| `profile.list` | Non-secret profile metadata | no |
| `profile.select` | Persist the active local profile | no |
| `profile.status` | Active profile and local persistence diagnostics | no |
| `profile.remove` | Delete a local credential copy after `confirm: true`; never deregisters the Audible device | yes |
| `auth.start` | Create an in-memory PKCE login and return its browser URL | no |
| `auth.complete` | Reserved; returns `INTERACTIVE_REQUIRED` in v1 | no |
| `library.list` | Cursor-paged owned titles | yes |
| `library.search` | Cursor-paged owned-title search | yes |
| `library.refresh` | Refresh the authenticated owned-title cache | no |
| `wishlist.list` | List wishlist titles for a profile | no |
| `wishlist.add` | Add one ASIN after explicit UI confirmation | no |
| `wishlist.remove` | Remove one ASIN after explicit UI confirmation | no |
| `downloads.list` | Durable download jobs | no |
| `downloads.start` | Queue an owned title | use job cancellation |
| `downloads.cancel` | Cancel a job by job ID | no |
| `player.status` | Observed mpv state | no |
| `player.command` | Transport/property command | no |
| `cancel` | Cancel an in-flight request by request ID | no |

`player.command` with `command: "play"` accepts the local media `path` plus
optional `itemId`, `title`, and `profile` metadata. Supplying the library title
keeps display text independent of the sanitized on-disk filename.
Playback commands also include `bookmark-add`, `bookmark-delete`,
`chapter-set`, `set-sleep-timer`, `cancel-sleep-timer`, and
`sleep-end-chapter`. Player status reports the durable bookmark list, a bounded
mpv chapter list (`index`, `title`, and `start_seconds`), plus sleep-timer mode
and remaining seconds.

Wishlist mutations accept a single `asin` and optional `profile`. They are
never retried automatically: callers must obtain an explicit confirmation for
each add or remove action. `wishlist.list` returns the same non-secret title
metadata shape used by `library.list`.

For offline development and local-library imports, `downloads.start` also
accepts `localPath`, with optional `itemId` and `outputDir`. This copies only a
regular local file through the resumable `.part`/atomic-rename path; `localPath`
is never interpreted as a URL and must never carry credentials, signed URLs, or
other secrets. Normal Audible downloads identify an owned title with `asin`.

`downloads.start` returns after durably queuing the job; it does not wait for
the transfer. At most two workers run concurrently. `downloads.list` reads the
owner-only job records, acts as the recovery heartbeat for stale workers, and
is the authoritative progress channel, so queued, active, failed, cancelled,
and completed states survive both TUI and engine restarts. Detached workers
never inherit the RPC stdout pipe, allowing the engine and TUI to close while a
transfer continues. An interrupted or cancelled job retains its `.part` file,
and submitting the same job again resumes it while preserving its attempt
count. Completed Audible jobs may also report `coverPath`, `pdfPath`,
`metadataPath`, `chaptersPath`, and `annotationsPath`; those sidecars are
created only when the corresponding API metadata exists. Chapter and annotation
JSON is bounded, parsed, and rejected if it contains credential or license
fields. Signed URLs and voucher contents are never job fields or metadata
sidecars.

Download cancellation is cooperative and durable. A successful
`downloads.cancel` writes a cancellation marker which workers check between
chunks; the partial file remains resumable. Unknown or already-terminal jobs
return `{cancelled:false}`.

Events omit `id` and use `{v,event,data}`. Version 1 reserves
`download.progress`, `download.state`, `player.state`, and
`engine.shutting-down`. Consumers must ignore unknown fields inside result/data
models but reject unknown envelope fields; this lets payloads grow without
making framing ambiguous.

## Compatibility rules

- A protocol version changes when an envelope, method, existing field meaning,
  or error semantic changes incompatibly.
- New optional payload fields and new event names are backward-compatible.
- Unknown versions are rejected; there is no implicit downgrade.
- Stdout is protocol-only. Logs and human diagnostics use stderr.
- There is no authentication secret transport in version 1.
- `auth.complete` refuses before exchanging the one-time browser code. Use the
  interactive `audible-zig quickstart`. Its encryption passphrase input is
  hidden; its callback URL input is visible so a long paste can be checked.
  Neither value is logged or transported over RPC.
