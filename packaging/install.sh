#!/bin/sh
set -eu

auditui_package_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
auditui_prefix=${AUDITUI_INSTALL_PREFIX:-${AUDIBLE_TUI_INSTALL_PREFIX:-$HOME/.local}}
auditui_bin_dir=${auditui_prefix}/bin

install -d -m 0755 "$auditui_bin_dir"
install -m 0755 "$auditui_package_dir/bin/auditui" "$auditui_bin_dir/auditui"
install -m 0755 "$auditui_package_dir/bin/auditui-ui" "$auditui_bin_dir/auditui-ui"
install -m 0755 "$auditui_package_dir/bin/auditui-engine" "$auditui_bin_dir/auditui-engine"

printf 'Installed Auditui to %s\n' "$auditui_bin_dir"
