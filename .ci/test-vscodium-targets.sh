#!/usr/bin/env bash
# .ci/test-vscodium-targets.sh — proves the per-OS VSCodium target state and
# single-source settings/keybindings parity WITHOUT touching a live HOME:
# everything is computed from chezmoi's source state with --override-data and
# an empty config, never applied.
#
# Asserts, per OS:
#   - `chezmoi managed` lists exactly the native target paths (Linux XDG,
#     Windows %APPDATA%, macOS Library/Application Support) and the matching
#     extension reconciler, and none of the foreign ones;
#   - .chezmoiignore renders the gates that produce that state;
#   - all three OS targets render BYTE-IDENTICAL settings.json (one shared
#     template) and keybindings.json (one literal include);
#   - the Windows PowerShell reconciler renders with the declared extension
#     set and its fail-closed authority guard rejects a malformed ID at
#     render time.
set -euo pipefail
repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
scratch_root="${XDG_RUNTIME_DIR:-$HOME/.cache}/agent-scratch"
mkdir -p "$scratch_root"
scratch=$(mktemp -d "$scratch_root/vscodium-targets.XXXXXX")
trap 'rm -rf -- "$scratch"' EXIT
mkdir -p "$scratch/source/dot_config" "$scratch/source/AppData/Roaming" "$scratch/source/Library/Application Support" "$scratch/source/.chezmoiscripts"
cp -a "$repo_root/.chezmoidata" "$repo_root/.chezmoitemplates" "$repo_root/.chezmoiignore" "$scratch/source/"
cp -a "$repo_root/dot_config/VSCodium" "$scratch/source/dot_config/"
cp -a "$repo_root/AppData/Roaming/VSCodium" "$scratch/source/AppData/Roaming/"
cp -a "$repo_root/Library/Application Support/VSCodium" "$scratch/source/Library/Application Support/"
cp -a "$repo_root/.chezmoiscripts/30-linux" "$repo_root/.chezmoiscripts/30-windows" "$scratch/source/.chezmoiscripts/"
printf '[data]\n' >"$scratch/empty.toml"

override_data() { # override_data <os> <arch>
  local os_release=
  [ "$1" != linux ] || os_release=fedora
  printf '{"chezmoi":{"os":"%s","arch":"%s","osRelease":{"id":"%s"}}}' "$1" "$2" "$os_release"
}

render() { # render <os> <arch> <file-relative-path> — execute-template from the real source
  chezmoi --config "$scratch/empty.toml" --source "$repo_root" --refresh-externals=never \
    --override-data "$(override_data "$1" "$2")" execute-template \
    <"$repo_root/$3"
}

managed() { # managed <os> <arch>
  chezmoi --config "$scratch/empty.toml" --source "$scratch/source" --refresh-externals=never \
    --override-data "$(override_data "$1" "$2")" managed
}

expect_line() { # expect_line <haystack-file> <exact-line> <what>
  if ! grep -qxF -- "$2" "$1"; then
    echo "MISSING $3: $2" >&2
    exit 1
  fi
}
reject_match() { # reject_match <haystack-file> <substring> <what>
  if grep -qF -- "$2" "$1"; then
    echo "UNEXPECTED $3: $2" >&2
    exit 1
  fi
}

# --- Linux -----------------------------------------------------------------
managed linux amd64 | grep -i vscodium >"$scratch/managed-linux"
expect_line "$scratch/managed-linux" '.config/VSCodium/User/settings.json' 'linux settings target'
expect_line "$scratch/managed-linux" '.config/VSCodium/User/keybindings.json' 'linux keybindings target'
expect_line "$scratch/managed-linux" '.chezmoiscripts/30-linux/install-vscodium-extensions.sh' 'linux POSIX reconciler'
reject_match "$scratch/managed-linux" 'AppData' 'linux must not manage AppData'
reject_match "$scratch/managed-linux" 'Library' 'linux must not manage Library'
reject_match "$scratch/managed-linux" '30-windows' 'linux must not manage the ps1 reconciler'

render linux amd64 .chezmoiignore >"$scratch/ignore-linux"
reject_match "$scratch/ignore-linux" '.config/VSCodium' 'linux must keep the XDG target'
expect_line "$scratch/ignore-linux" './AppData' 'linux AppData gate'
expect_line "$scratch/ignore-linux" './Library' 'linux Library gate'
expect_line "$scratch/ignore-linux" '.chezmoiscripts/30-windows/*.ps1' 'linux ps1 reconciler gate'

# --- Windows ---------------------------------------------------------------
managed windows amd64 | grep -i vscodium >"$scratch/managed-windows"
expect_line "$scratch/managed-windows" 'AppData/Roaming/VSCodium/User/settings.json' 'windows settings target'
expect_line "$scratch/managed-windows" 'AppData/Roaming/VSCodium/User/keybindings.json' 'windows keybindings target'
expect_line "$scratch/managed-windows" '.chezmoiscripts/30-windows/install-vscodium-extensions.ps1' 'windows ps1 reconciler'
reject_match "$scratch/managed-windows" '.config/VSCodium' 'windows must not manage the XDG path'
reject_match "$scratch/managed-windows" 'Library' 'windows must not manage Library'

render windows amd64 .chezmoiignore >"$scratch/ignore-windows"
expect_line "$scratch/ignore-windows" '.config/VSCodium' 'windows XDG gate'
expect_line "$scratch/ignore-windows" './Library' 'windows Library gate'
reject_match "$scratch/ignore-windows" './AppData' 'windows must keep AppData'
reject_match "$scratch/ignore-windows" '30-windows' 'windows must keep the ps1 reconciler'

# --- macOS -----------------------------------------------------------------
managed darwin arm64 | grep -i vscodium >"$scratch/managed-darwin"
expect_line "$scratch/managed-darwin" 'Library/Application Support/VSCodium/User/settings.json' 'darwin settings target'
expect_line "$scratch/managed-darwin" 'Library/Application Support/VSCodium/User/keybindings.json' 'darwin keybindings target'
expect_line "$scratch/managed-darwin" '.chezmoiscripts/30-linux/install-vscodium-extensions.sh' 'darwin POSIX reconciler'
reject_match "$scratch/managed-darwin" '.config/VSCodium' 'darwin must not manage the XDG path'
reject_match "$scratch/managed-darwin" 'AppData' 'darwin must not manage AppData'
reject_match "$scratch/managed-darwin" '30-windows' 'darwin must not manage the ps1 reconciler'

render darwin arm64 .chezmoiignore >"$scratch/ignore-darwin"
expect_line "$scratch/ignore-darwin" '.config/VSCodium' 'darwin XDG gate'
expect_line "$scratch/ignore-darwin" './AppData' 'darwin AppData gate'
expect_line "$scratch/ignore-darwin" '.chezmoiscripts/30-windows/*.ps1' 'darwin ps1 reconciler gate'
reject_match "$scratch/ignore-darwin" './Library' 'darwin must keep Library'

# --- Single-source content parity -------------------------------------------
# Every OS target must render byte-identical settings (shared template) and
# keybindings (literal include), under every OS context.
for os_arch in 'linux amd64' 'windows amd64' 'darwin arm64'; do
  read -r os arch <<<"$os_arch"
  render "$os" "$arch" dot_config/VSCodium/User/settings.json.tmpl >"$scratch/settings-ref"
  render "$os" "$arch" AppData/Roaming/VSCodium/User/settings.json.tmpl >"$scratch/settings-win"
  render "$os" "$arch" 'Library/Application Support/VSCodium/User/settings.json.tmpl' >"$scratch/settings-mac"
  cmp "$scratch/settings-ref" "$scratch/settings-win" || { echo "settings drift: windows wrapper ($os)" >&2; exit 1; }
  cmp "$scratch/settings-ref" "$scratch/settings-mac" || { echo "settings drift: darwin wrapper ($os)" >&2; exit 1; }
  render "$os" "$arch" AppData/Roaming/VSCodium/User/keybindings.json.tmpl >"$scratch/keys-win"
  render "$os" "$arch" 'Library/Application Support/VSCodium/User/keybindings.json.tmpl' >"$scratch/keys-mac"
  cmp "$repo_root/dot_config/VSCodium/User/keybindings.json" "$scratch/keys-win" || { echo "keybindings drift: windows wrapper ($os)" >&2; exit 1; }
  cmp "$repo_root/dot_config/VSCodium/User/keybindings.json" "$scratch/keys-mac" || { echo "keybindings drift: darwin wrapper ($os)" >&2; exit 1; }
done
# The rendered settings stay valid JSON.
python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$scratch/settings-ref"

# --- Windows reconciler: managed set + fail-closed render guard -------------
render windows amd64 .chezmoiscripts/30-windows/run_onchange_after_install-vscodium-extensions.ps1.tmpl \
  >"$scratch/reconcile.ps1"
# Every ID declared in the authority renders into the ps1 managed set.
while IFS= read -r ext; do
  expect_line "$scratch/reconcile.ps1" "  \"$ext\"" "ps1 managed extension $ext"
done < <(sed -n 's/^    - //p' "$repo_root/.chezmoidata/vscodium.yaml")
# A malformed authority entry fails the RENDER, before any mutation can run.
if chezmoi --config "$scratch/empty.toml" --source "$repo_root" \
  --override-data '{"chezmoi":{"os":"windows","arch":"amd64"},"vscodium":{"extensions":["not a gallery id"]}}' \
  execute-template \
  <"$repo_root/.chezmoiscripts/30-windows/run_onchange_after_install-vscodium-extensions.ps1.tmpl" \
  >"$scratch/bad.ps1" 2>"$scratch/bad.err"; then
  echo 'render-time authority guard accepted a malformed extension ID' >&2
  exit 1
fi
grep -q 'publisher.name' "$scratch/bad.err" || { echo 'render failure did not name the authority violation' >&2; exit 1; }

printf '%s\n' 'vscodium target parity passed'
