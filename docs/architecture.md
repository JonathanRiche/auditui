# Architecture

Auditui is two programs joined by a deliberately small protocol:

```text
Bun + TypeScript + OpenTUI
        | newline-delimited JSON over private stdin/stdout pipes
Zig engine (`audible internal rpc`)
        |-- Audible HTTP services and profile credentials
        |-- SQLite non-secret state and download files
        `-- private mpv JSON IPC connection
```

The engine owns authentication, networking, persistence, downloads, and mpv.
The TUI owns presentation and input. Human CLI output is never parsed by the
TUI. The engine writes only protocol messages to stdout while in RPC mode;
sanitized diagnostics go to stderr.

On the current Zig 0.16/GCC 16 development host, link-time `libsqlite3` use is
not reliable (`.sframe` relocation failure with the native path and a compiler
server crash with LLD). The MVP therefore invokes the installed `sqlite3` CLI
with a direct argument vector and bounded output; it never constructs a shell
command. This keeps migrations and non-secret state operational while avoiding
a compiler-specific crash. Native library linkage should be revisited when the
toolchain is upgraded and tested.

## Runtime boundaries

- One TUI launches one engine child and closes its stdin for graceful shutdown.
- Request IDs are opaque strings scoped to a connection. Events may interleave
  with responses. The TUI must match responses by ID rather than arrival order.
- Backpressure is bounded. Progress events may be coalesced; terminal state
  events and responses may not be dropped.
- The engine is independently useful through the compatible human CLI.
- General state follows XDG data/state/cache directories. Credential files are
  kept outside SQLite and require private directory/file permissions.
- Downloads use a `.part` sibling and an atomic final rename. Completed files
  are not overwritten without explicit intent.
- mpv receives an argument vector, not a shell string, and is supervised by the
  engine through a private IPC endpoint.

## Failure behavior

Malformed input produces a correlated `INVALID_REQUEST` response when an ID can
be recovered, otherwise an empty sentinel ID is permitted only for that parse
failure. EOF initiates shutdown. A crashed engine is surfaced to the user; the
TUI may restart it, but may not silently repeat mutation requests. SQLite and
credential writes use transactions or write-fsync-rename as appropriate.

See [protocol.md](protocol.md), [authentication.md](authentication.md), and the
[threat model](threat-model.md).
