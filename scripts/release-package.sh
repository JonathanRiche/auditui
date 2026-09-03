#!/bin/sh
set -eu

auditui_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
auditui_version=$(sed -n 's/^[[:space:]]*"version": "\([^"]*\)",$/\1/p' "$auditui_root/tui/package.json")
auditui_arch=$(uname -m)
auditui_platform=$(uname -s | tr '[:upper:]' '[:lower:]')
auditui_dist=${AUDITUI_DIST_DIR:-${AUDIBLE_TUI_DIST_DIR:-$auditui_root/dist}}
auditui_name=auditui-${auditui_version}-${auditui_platform}-${auditui_arch}
auditui_asset=auditui-${auditui_platform}-${auditui_arch}.tar.gz
auditui_stage=$(mktemp -d)
trap 'rm -rf -- "$auditui_stage"' EXIT HUP INT TERM

mkdir -p "$auditui_dist" "$auditui_stage/$auditui_name/bin"
cd "$auditui_root"
mise run zig:build-release
mise exec -- bun build tui/src/main.ts --compile --outfile "$auditui_stage/$auditui_name/bin/auditui-ui"
install -m 0755 engine/zig-out/bin/audible-zig "$auditui_stage/$auditui_name/bin/auditui-engine"
install -m 0755 packaging/auditui "$auditui_stage/$auditui_name/bin/auditui"
install -m 0755 packaging/install.sh "$auditui_stage/$auditui_name/install.sh"
install -m 0644 LICENSE NOTICE README.md THIRD_PARTY_NOTICES.md "$auditui_stage/$auditui_name/"

auditui_archive=$auditui_dist/$auditui_asset
tar --sort=name --mtime='@0' --owner=0 --group=0 --numeric-owner -C "$auditui_stage" -czf "$auditui_archive" "$auditui_name"
(cd "$auditui_dist" && sha256sum "$auditui_asset" > "$auditui_asset.sha256")
printf '%s\n' "$auditui_archive"
