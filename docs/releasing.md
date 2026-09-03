# Releasing Auditui

Public releases are built by GitHub Actions from version tags. End users do not
need the source tree, Mise, Zig, or Bun.

## Publish

1. Update the version in `tui/package.json` and both lockfiles.
2. Run `mise run release:check` locally.
3. Commit the release and push a matching tag such as `v0.1.0`.

The `Release` workflow repeats the complete quality gate, builds the Linux
x86_64 package, and creates a GitHub Release with these stable asset names:

```text
auditui-linux-x86_64.tar.gz
auditui-linux-x86_64.tar.gz.sha256
```

Stable names allow GitHub's `/releases/latest/download/...` URL to power the
one-line installer without querying an API. The archive still contains a
versioned root directory.

## User installation

```sh
curl -fsSL https://raw.githubusercontent.com/JonathanRiche/auditui/main/install.sh | sh
auditui auth login
auditui
```

Yoto users must create a dashboard Public Client and register
`http://127.0.0.1:8787/callback` before running:

```sh
YOTO_CLIENT_ID=your-public-client-id auditui auth login --provider yoto
```

The bootstrap script detects the supported platform, downloads both assets,
verifies SHA-256 before extraction, and installs to `~/.local/bin`. Set
`AUDITUI_INSTALL_PREFIX` to choose a different prefix.

## Local package verification

```sh
mise run release:check
sha256sum -c dist/auditui-linux-x86_64.tar.gz.sha256
```

The release gate verifies formatting, linting, types, Zig and TUI tests,
protocol and compatibility contracts, durable download and mpv integration,
secret scanning, license metadata, a clean dependency install, 80×24 startup,
the package installer, the remote-style bootstrap installer, database
migrations, packaged Audible and Yoto command routing, and the packaged Yoto
provider guide.

Live Audible authentication is intentionally opt-in and remains a manual
pre-release check because it uses private account data and an interactive
terminal.
