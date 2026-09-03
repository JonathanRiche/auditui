#!/bin/sh
set -eu

auditui_repository=${AUDITUI_REPOSITORY:-JonathanRiche/auditui}
auditui_prefix=${AUDITUI_INSTALL_PREFIX:-$HOME/.local}
auditui_asset=auditui-linux-x86_64.tar.gz

if [ "$(uname -s)" != Linux ]; then
  printf '%s\n' 'Auditui currently supports Linux.' >&2
  exit 1
fi

case "$(uname -m)" in
  x86_64|amd64) ;;
  *)
    printf 'Auditui does not have a release for architecture %s yet.\n' "$(uname -m)" >&2
    exit 1
    ;;
esac

for auditui_command in curl grep sha256sum tar; do
  command -v "$auditui_command" >/dev/null 2>&1 || {
    printf 'Auditui installation requires %s.\n' "$auditui_command" >&2
    exit 1
  }
done

auditui_release_base=${AUDITUI_RELEASE_BASE_URL:-https://github.com/${auditui_repository}/releases/latest/download}
auditui_temporary=$(mktemp -d)
trap 'rm -rf -- "$auditui_temporary"' EXIT HUP INT TERM

printf '%s\n' 'Downloading Auditui…'
curl --proto '=https,file' --tlsv1.2 --location --fail --show-error --silent \
  "$auditui_release_base/$auditui_asset" \
  --output "$auditui_temporary/$auditui_asset"
curl --proto '=https,file' --tlsv1.2 --location --fail --show-error --silent \
  "$auditui_release_base/$auditui_asset.sha256" \
  --output "$auditui_temporary/$auditui_asset.sha256"

(cd "$auditui_temporary" && sha256sum -c "$auditui_asset.sha256")
mkdir "$auditui_temporary/package"
tar -xzf "$auditui_temporary/$auditui_asset" -C "$auditui_temporary/package"
auditui_package_dir=$(find "$auditui_temporary/package" -mindepth 1 -maxdepth 1 -type d -name 'auditui-*' -print -quit)
[ -n "$auditui_package_dir" ] || {
  printf '%s\n' 'Auditui release archive did not contain the expected package.' >&2
  exit 1
}

AUDITUI_INSTALL_PREFIX=$auditui_prefix "$auditui_package_dir/install.sh"

auditui_path_ready=0
case ":${PATH}:" in
  *":$auditui_prefix/bin:"*) auditui_path_ready=1 ;;
esac

auditui_shell_name=${AUDITUI_SHELL:-${SHELL:-}}
auditui_shell_name=${auditui_shell_name##*/}
auditui_reload_command=

if [ "$auditui_path_ready" -eq 0 ] && [ "${AUDITUI_NO_PATH_UPDATE:-0}" != 1 ]; then
  if [ "$auditui_prefix" = "$HOME/.local" ]; then
    case "$auditui_shell_name" in
      bash)
        auditui_shell_file=$HOME/.bashrc
        auditui_path_line='export PATH="$HOME/.local/bin:$PATH"'
        auditui_reload_command='source ~/.bashrc'
        ;;
      zsh)
        auditui_shell_file=$HOME/.zshrc
        auditui_path_line='export PATH="$HOME/.local/bin:$PATH"'
        auditui_reload_command='source ~/.zshrc'
        ;;
      fish)
        auditui_shell_directory=$HOME/.config/fish/conf.d
        mkdir -p "$auditui_shell_directory"
        auditui_shell_file=$auditui_shell_directory/auditui.fish
        auditui_path_line='fish_add_path --global --prepend "$HOME/.local/bin"'
        auditui_reload_command='source ~/.config/fish/conf.d/auditui.fish'
        ;;
      *)
        auditui_shell_file=
        ;;
    esac

    if [ -n "$auditui_shell_file" ]; then
      if ! [ -f "$auditui_shell_file" ] || ! grep -Fqx "$auditui_path_line" "$auditui_shell_file"; then
        printf '\n%s\n%s\n' '# Added by the Auditui installer.' "$auditui_path_line" >> "$auditui_shell_file"
      fi
      printf 'Added %s/bin to PATH in %s.\n' "$auditui_prefix" "$auditui_shell_file"
    fi
  fi
fi

if [ "$auditui_path_ready" -eq 0 ]; then
  if [ -n "$auditui_reload_command" ]; then
    printf 'Activate it now with: %s\n' "$auditui_reload_command"
  else
    printf 'Add %s/bin to PATH for your shell.\n' "$auditui_prefix"
  fi
fi

printf '%s\n' 'Run: auditui auth login'
printf '%s\n' 'Then: auditui'
