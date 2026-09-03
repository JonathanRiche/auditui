# Native feasibility report

Status on 2026-09-03: **the native Canadian-marketplace application path is
proven on the authorized development account**. The evidence was collected
interactively and sanitized: no credential, account identifier, ASIN, title,
signed URL, voucher, activation material, or media was copied into the source
tree or test output.

| Spike | Evidence available | Decision / blocker |
|---|---|---|
| Native external-browser authentication | New Canadian profile authorized and stored with owner-only permissions | Proven interactively for both encrypted and explicitly selected unencrypted storage |
| Authenticated library request and refresh | Native Zig request returned newly purchased titles; manual refresh and startup refresh updated the cache | Proven read-only; endpoint stability remains an external risk |
| Refresh and atomic persistence | Cache survived restart and newly purchased titles appeared without Python in the runtime path | Proven on the development account plus offline atomic-write tests |
| Existing-profile import | Plain/encrypted upstream shapes and permission enforcement have automated coverage | Proven offline; import remains non-destructive |
| Owned AAXC download | Native license, voucher, resumable transfer, private storage, and repeated-download reuse completed | Proven with owned short samples; private response data was not retained as fixtures |
| mpv AAXC playback and seek | mpv opened the protected download, reported a decoded duration of 680.83 seconds, and playback/seek controls advanced | Proven interactively; synthetic IPC tests remain the CI-safe regression gate |
| Concurrent OpenTUI ↔ Zig messages | Real Bun/OpenTUI client and Zig RPC engine exchange correlated responses and interleaved events | Proven offline, including engine lifecycle and malformed-message tests |

## Go/no-go gates

Repeat the opt-in check before a release whenever authentication, signing,
download, or playback code changes. A passing run records tool versions, media
kind, status/result shape, seek tolerance, and timestamps—never tokens, account
identity, ASIN/title, paths, signed URLs, activation bytes, vouchers, or media.

Before a live run, verify the profile directory is user-only and credential file
is `0600`; fail closed otherwise. Copy only into a `0700` temporary directory,
delete the copy afterward, and do not print or snapshot its contents. Use the
smallest owned-title sample and make only read-only requests except the token
refresh inherently required for that request.

## Current architectural conclusion

The two-process architecture now covers both offline/local and authorized live
operation. A real TUI session authenticated, refreshed, displayed native cover
art, downloaded owned AAXC files, played, paused, and sought without Python in
the runtime path. Resumable transfer, cancellation/retry, atomic promotion, mpv
IPC, protocol validation, and SQLite migrations also have offline automated
gates. NDJSON keeps the boundary independently testable, while mpv isolates
media decoding from both Zig and the TUI.

This evidence proves feasibility, not control over Audible's private service.
Marketplace endpoints, response shapes, and login policy can still change.
