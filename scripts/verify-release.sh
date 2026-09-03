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
"$auditui_prefix/bin/auditui" --version | rg -q '^Auditui 0\.1\.0$'
"$auditui_prefix/bin/auditui" --help | rg -q 'auditui auth login'
auditui_login_args=$(AUDITUI_ENGINE=/bin/echo "$auditui_prefix/bin/auditui" auth login --profile reader --country-code ca --no-encryption)
test "$auditui_login_args" = 'quickstart --profile reader --country-code ca --no-encryption'
auditui_default_login_args=$(AUDITUI_ENGINE=/bin/echo "$auditui_prefix/bin/auditui" auth login)
test "$auditui_default_login_args" = 'quickstart --profile default --country-code us'

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

printf 'Release archive, checksum, bootstrap install, migrations, and packaged CLI smoke test passed.\n'
