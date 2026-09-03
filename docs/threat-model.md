# Threat model

## Scope and assets

Protected assets are access/refresh/ADP tokens, RSA device keys, cookies,
passwords, activation bytes, AAXC vouchers, signed URLs, owned media, listening
history, bookmarks, and account/library metadata. Trust boundaries are the TUI ↔
engine pipe, engine ↔ Audible HTTPS, engine ↔ mpv IPC, local storage, external
browser callback, logs/crash reports, and downloaded filenames.

## Threats and controls

| Threat | Control | Verification |
|---|---|---|
| Another local user reads credentials | `0700` directory, `0600` files, owner/type/link checks before read | permission tests fail closed |
| Secret leaks through CLI, logs, RPC, crash output | no secret argv/env parameters; centralized redaction; protocol allowlists; stdout separation | canary secret/redaction tests and repository scan |
| Malicious import path or symlink overwrites files | no-follow validation, regular-file and link-count checks, private temp file, same-directory atomic rename | symlink/hard-link/race tests |
| Compromised TUI sends arbitrary API calls | versioned method allowlist; no raw API method in RPC; typed parameter validation | unknown/malformed method contract tests |
| NDJSON injection or unbounded messages exhaust memory | one object per line, UTF-8/JSON validation, maximum line/payload sizes, bounded queues | fuzz and oversize tests |
| Path traversal or shell injection from titles | sanitize to a filename component; canonical output-root containment; argument vectors only | hostile-title fixtures |
| Download corruption or overwrite | `.part`, range/validator checks, length/checksum validation, atomic rename, no default overwrite | interrupted/truncated server tests |
| Replay/retry repeats a mutation | retry only idempotent requests automatically; no silent TUI replay after engine crash | fault-injection tests |
| Rogue process controls or observes mpv | random private IPC path in `0700` runtime directory; verify ownership; remove on exit | local IPC permissions test |
| Browser redirect is forged | high-entropy state/PKCE where supported, exact redirect validation, short-lived pending login | negative callback tests |
| Dependency/update compromise | exact versions and lockfiles; provenance/checksum verification; review native dependencies | clean-machine reproducible build |
| Live test mutates an account | opt-in flag, read-only endpoint allowlist, dedicated-account recommendation | test harness policy test |

## Abuse cases deliberately unsupported

The application does not purchase titles, spend credits, bypass ownership, or
bulk-export credentials. Wishlist mutations require explicit user action.
Remote deregistration is never bundled with local logout. Raw API support in the
human compatibility CLI is powerful and must display a warning for mutating
methods; it is not exposed to the TUI protocol.

## Residual risks

Audible endpoints and login behavior are unofficial and may change. A process
running as the same OS user can often inspect memory or control the process;
filesystem permissions do not defend against that adversary. mpv and terminal
emulators process attacker-influenced metadata, so dependencies remain part of
the trusted computing base. DRM-related use may be restricted by contract or
law; users are responsible for their jurisdiction and account terms.

Review this model before enabling authentication, downloads, remote mutations,
debug bundles, or distribution, and after any protocol or storage change.
