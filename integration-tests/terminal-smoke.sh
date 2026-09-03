#!/bin/sh
set -eu

audible_tui_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
audible_tui_terminal=$(mktemp -d)
trap 'rm -rf -- "$audible_tui_terminal"' EXIT HUP INT TERM
mkdir -p "$audible_tui_terminal/config" "$audible_tui_terminal/data" \
  "$audible_tui_terminal/state" "$audible_tui_terminal/cache" "$audible_tui_terminal/library"

printf 'q' | timeout 10s script -qfec \
  "stty cols 80 rows 24; env TERM=xterm-256color AUDIBLE_CONFIG_DIR=$audible_tui_terminal/config AUDIBLE_DATA_DIR=$audible_tui_terminal/data AUDIBLE_STATE_DIR=$audible_tui_terminal/state AUDIBLE_CACHE_DIR=$audible_tui_terminal/cache AUDIBLE_LIBRARY_DIR=$audible_tui_terminal/library AUDIBLE_TUI_IMAGE_PROTOCOL=blocks AUDIBLE_ENGINE=$audible_tui_root/engine/zig-out/bin/audible-zig bun run $audible_tui_root/tui/src/main.ts" \
  /dev/null >/dev/null

test -f "$audible_tui_terminal/state/audible-tui.db"
printf 'Generic 80x24 PTY and portable block-image startup/shutdown passed.\n'
