#!/bin/bash
# Install ibrew on the Intel MacBook. Run from a checkout of this repo:
#   client/setup.sh <github-user>/<repo>
set -euo pipefail

repo="${1:?usage: client/setup.sh owner/repo}"
root="$(cd "$(dirname "$0")/.." && pwd)"
share="$HOME/.local/share/ibrew"
bin="$HOME/.local/bin"
config_dir="${XDG_CONFIG_HOME:-$HOME/.config}/ibrew"

[[ "$(uname -m)" == x86_64 ]] || echo "warning: this is not an Intel Mac; the bottles won't fit" >&2
[[ "$(brew --prefix)" == /usr/local ]] || echo "warning: brew prefix is not /usr/local; the bottles won't fit" >&2

mkdir -p "$share" "$bin" "$config_dir"
install -m 0644 "$root/scripts/bottler.rb" "$share/bottler.rb"
install -m 0755 "$root/client/ibrew" "$bin/ibrew"
printf '%s\n' "$repo" >"$config_dir/repo"

if security find-generic-password -s ibrew -a "$repo" >/dev/null 2>&1; then
  echo "GitHub token for $repo already in the Keychain."
else
  echo "Paste a fine-grained GitHub token (repo $repo only, Actions: read and write)."
  # -w last makes `security` prompt, so the token never lands in shell history.
  security add-generic-password -s ibrew -a "$repo" -l "ibrew GitHub token" -w
fi

echo "Installed ibrew to $bin/ibrew."
case ":$PATH:" in
  *":$bin:"*) ;;
  *) echo "Add it to your PATH:  echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.zshrc" ;;
esac
echo "Optional, to make plain 'brew' use it:  echo 'alias brew=ibrew' >> ~/.zshrc"
