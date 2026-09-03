#!/bin/sh
set -eu

auditui_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
auditui_dist=${AUDITUI_DIST_DIR:-${AUDIBLE_TUI_DIST_DIR:-$auditui_root/dist}}
auditui_archive=$(find "$auditui_dist" -maxdepth 1 -type f -name 'auditui-*.tar.gz' -print | sort | tail -n 1)
test -n "$auditui_archive"
(cd "$auditui_dist" && sha256sum -c "$(basename "$auditui_archive").sha256")

if tar -tzf "$auditui_archive" | rg -i '(auth.*\.json|\.aaxc?$|\.voucher$|activation[-_.]?bytes|\.db(?:-shm|-wal)?$|\.pem$)'; then
  printf 'Release contains forbidden private material.\n' >&2
  exit 1
fi

auditui_verify=$(mktemp -d)
trap 'rm -rf -- "$auditui_verify"' EXIT HUP INT TERM
tar -xzf "$auditui_archive" -C "$auditui_verify"
auditui_package=$(find "$auditui_verify" -mindepth 1 -maxdepth 1 -type d -print | head -n 1)
auditui_prefix=$auditui_verify/install-root
AUDITUI_INSTALL_PREFIX=$auditui_prefix "$auditui_package/install.sh"
test -x "$auditui_prefix/bin/auditui"
test -x "$auditui_prefix/bin/auditui-ui"
test -x "$auditui_prefix/bin/auditui-engine"
# The engine must run on any x86-64 CPU, not just the build host's.
if objdump -d "$auditui_prefix/bin/auditui-engine" | rg -q '\b[yz]mm[0-9]'; then
  printf 'Packaged engine uses non-baseline vector instructions; build with -Dcpu=baseline.\n' >&2
  exit 1
fi
"$auditui_prefix/bin/auditui" --version | rg -q '^Auditui 0\.3\.3$'
"$auditui_prefix/bin/auditui" --help | rg -q 'auditui auth login'
"$auditui_prefix/bin/auditui" --help | rg -q -- '--provider NAME'
test -f "$auditui_package/docs/yoto-provider.md"
auditui_ui_engine=$(AUDITUI_UI=/usr/bin/env "$auditui_prefix/bin/auditui" | rg '^AUDITUI_ENGINE=' || true)
test "$auditui_ui_engine" = "AUDITUI_ENGINE=$auditui_prefix/bin/auditui-engine"
auditui_login_args=$(AUDITUI_ENGINE=/bin/echo "$auditui_prefix/bin/auditui" auth login --profile reader --country-code ca --no-encryption)
test "$auditui_login_args" = 'quickstart --profile reader --country-code ca --no-encryption'
auditui_default_login_args=$(AUDITUI_ENGINE=/bin/echo "$auditui_prefix/bin/auditui" auth login)
test "$auditui_default_login_args" = 'quickstart --profile default --country-code us'
auditui_yoto_login_args=$(AUDITUI_ENGINE=/bin/echo "$auditui_prefix/bin/auditui" auth login --provider yoto --account family --client-id public-client)
test "$auditui_yoto_login_args" = 'auth login --provider yoto --account family --client-id public-client'
auditui_yoto_env_login_args=$(YOTO_CLIENT_ID=public-client AUDITUI_ENGINE=/bin/echo "$auditui_prefix/bin/auditui" auth login --provider yoto --profile reader)
test "$auditui_yoto_env_login_args" = 'auth login --provider yoto --account reader'
auditui_yoto_refresh_args=$(AUDITUI_ENGINE=/bin/echo "$auditui_prefix/bin/auditui" library refresh --provider yoto --account family)
test "$auditui_yoto_refresh_args" = 'library refresh --provider yoto --account family'

auditui_xdg=$auditui_verify/xdg
mkdir -p "$auditui_xdg/config" "$auditui_xdg/data" "$auditui_xdg/state" "$auditui_xdg/cache"
printf '{"v":1,"id":"release-health","method":"health","params":{}}\n' |
  env AUDIBLE_CONFIG_DIR="$auditui_xdg/config" AUDIBLE_DATA_DIR="$auditui_xdg/data" \
    AUDIBLE_STATE_DIR="$auditui_xdg/state" AUDIBLE_CACHE_DIR="$auditui_xdg/cache" \
    "$auditui_prefix/bin/auditui-engine" internal rpc |
  rg -q '"id":"release-health".*"ok":true'

auditui_database=$auditui_xdg/state/audible-tui.db
test -f "$auditui_database"
auditui_tables=$(sqlite3 "$auditui_database" "SELECT count(*) FROM sqlite_master WHERE type='table' AND name IN ('schema_migrations','profiles','library_items','local_files','download_jobs','playback_positions','bookmarks','settings');")
test "$auditui_tables" = 8

auditui_bootstrap_prefix=$auditui_verify/bootstrap-root
AUDITUI_RELEASE_BASE_URL="file://$auditui_dist" \
  AUDITUI_INSTALL_PREFIX=$auditui_bootstrap_prefix \
  sh "$auditui_root/install.sh" >/dev/null
test -x "$auditui_bootstrap_prefix/bin/auditui"
"$auditui_bootstrap_prefix/bin/auditui" --help | rg -q 'auditui auth login'

for auditui_shell in bash zsh fish; do
  auditui_shell_home=$auditui_verify/shell-$auditui_shell
  mkdir -p "$auditui_shell_home"
  HOME=$auditui_shell_home AUDITUI_SHELL=/bin/$auditui_shell \
    AUDITUI_RELEASE_BASE_URL="file://$auditui_dist" \
    sh "$auditui_root/install.sh" >/dev/null
  test -x "$auditui_shell_home/.local/bin/auditui"
  case "$auditui_shell" in
    bash) rg -Fxq 'export PATH="$HOME/.local/bin:$PATH"' "$auditui_shell_home/.bashrc" ;;
    zsh) rg -Fxq 'export PATH="$HOME/.local/bin:$PATH"' "$auditui_shell_home/.zshrc" ;;
    fish) rg -Fxq 'fish_add_path --global --prepend "$HOME/.local/bin"' "$auditui_shell_home/.config/fish/conf.d/auditui.fish" ;;
  esac
  HOME=$auditui_shell_home AUDITUI_SHELL=/bin/$auditui_shell \
    AUDITUI_RELEASE_BASE_URL="file://$auditui_dist" \
    sh "$auditui_root/install.sh" >/dev/null
  case "$auditui_shell" in
    bash) test "$(rg -Fxc 'export PATH="$HOME/.local/bin:$PATH"' "$auditui_shell_home/.bashrc")" = 1 ;;
    zsh) test "$(rg -Fxc 'export PATH="$HOME/.local/bin:$PATH"' "$auditui_shell_home/.zshrc")" = 1 ;;
    fish) test "$(rg -Fxc 'fish_add_path --global --prepend "$HOME/.local/bin"' "$auditui_shell_home/.config/fish/conf.d/auditui.fish")" = 1 ;;
  esac
done

printf 'Release archive, checksum, shell PATH setup, migrations, and packaged CLI smoke test passed.\n'
