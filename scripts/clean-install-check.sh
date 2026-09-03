#!/bin/sh
set -eu

audible_tui_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
audible_tui_clean=$(mktemp -d)
trap 'rm -rf -- "$audible_tui_clean"' EXIT HUP INT TERM

mkdir -p "$audible_tui_clean/root" "$audible_tui_clean/tui"
install -m 0644 "$audible_tui_root/package.json" "$audible_tui_root/bun.lock" "$audible_tui_clean/root/"
install -m 0644 "$audible_tui_root/tui/package.json" "$audible_tui_root/tui/bun.lock" "$audible_tui_clean/tui/"
(cd "$audible_tui_clean/root" && bun install --frozen-lockfile)
(cd "$audible_tui_clean/tui" && bun install --frozen-lockfile)

test -x "$audible_tui_clean/root/node_modules/.bin/biome"
test -d "$audible_tui_clean/tui/node_modules/@opentui/core"
printf 'Fresh locked dependency installation passed.\n'
