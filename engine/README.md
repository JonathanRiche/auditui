# Audible Zig engine

The engine uses the XDG directories by default and accepts exact-path
`AUDIBLE_CONFIG_DIR`, `AUDIBLE_DATA_DIR`, `AUDIBLE_STATE_DIR`, and
`AUDIBLE_CACHE_DIR` overrides for isolated runs.

For a useful offline library without Audible authentication, set
`AUDIBLE_LIBRARY_DIR` to a directory of audiobooks. When `library.json` is
missing or has no items, `library.list` and `library.search` non-recursively
discover regular `.m4b`, `.mp3`, `.m4a`, `.ogg`, `.opus`, `.flac`, `.wav`,
`.aax`, and `.aaxc` files. The scanner reads filenames only; it does not inspect
media contents or credentials. Returned items are marked downloaded and include
the local path used by the TUI's mpv player.
