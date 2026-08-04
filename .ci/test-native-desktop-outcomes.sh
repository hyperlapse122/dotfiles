#!/usr/bin/env bash
# Focused U8 native desktop/hardware fixture. Proves the new authority rows
# reach the native reconcilers, manual/not-applicable dispositions emit no
# manager row, Korean input stays on native Windows/macOS IMEs with named
# manual steps, the macOS pinentry config names the managed formula, the
# encryption-status tools stay read-only and per-OS gated, and no new row
# closes or claims G0.
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
scratch_root="${XDG_RUNTIME_DIR:-$HOME/.cache}/agent-scratch"
mkdir -p "$scratch_root"
scratch=$(mktemp -d "$scratch_root/native-desktop.XXXXXX")
trap 'rm -rf -- "$scratch"' EXIT
mkdir -p "$scratch/bin"
printf '#!/usr/bin/env bash\nprintf dummy-secret\n' >"$scratch/bin/op"
chmod 700 "$scratch/bin/op"
printf '[data]\n' >"$scratch/empty.toml"

render() {
  local os=$1 arch=$2 template=$3 output=$4
  PATH="$scratch/bin:$PATH" chezmoi --config "$scratch/empty.toml" --source "$repo_root" \
    --override-data "{\"chezmoi\":{\"os\":\"$os\",\"arch\":\"$arch\"}}" \
    execute-template <"$repo_root/$template" >"$output"
}
fail() { printf 'native desktop outcomes: %s\n' "$*" >&2; exit 1; }
requires() { grep -F -- "$2" "$1" >/dev/null || fail "$1 is missing: $2"; }
forbids() { if grep -F -- "$2" "$1" >/dev/null; then fail "$1 must not contain: $2"; fi; }

render windows amd64 .chezmoiscripts/20-windows/run_onchange_before_winget.ps1.tmpl "$scratch/winget-x64.ps1"
render windows arm64 .chezmoiscripts/20-windows/run_onchange_before_winget.ps1.tmpl "$scratch/winget-arm64.ps1"
render darwin arm64 .chezmoiscripts/20-darwin/run_onchange_before_homebrew.sh.tmpl "$scratch/homebrew.sh"

# Managed U8 rows reach the native reconcilers on both architectures.
requires "$scratch/winget-x64.ps1" "Id = 'KDE.Kdenlive'"
requires "$scratch/winget-arm64.ps1" "Id = 'KDE.Kdenlive'"
requires "$scratch/homebrew.sh" 'cask "kdenlive"'
requires "$scratch/homebrew.sh" 'cask "weasis"'
requires "$scratch/homebrew.sh" 'brew "pinentry-mac"'
requires "$scratch/homebrew.sh" 'brew "defaultbrowser"'
# Logi Options+ presence (the U8 non-Linux gesture path) stays managed.
requires "$scratch/winget-x64.ps1" "Id = 'Logitech.OptionsPlus'"
requires "$scratch/homebrew.sh" 'cask "logi-options-plus"'

# Manual / not-applicable dispositions must never emit a manager row.
forbids "$scratch/winget-x64.ps1" 'Weasis'
forbids "$scratch/winget-x64.ps1" 'pinentry'
forbids "$scratch/winget-x64.ps1" 'fcitx'

# Korean input stays on the native Windows/macOS IMEs as named manual steps.
requires "$repo_root/.chezmoidata/packages.yaml" 'disposition: manual, reason: native Windows Korean IME'
requires "$repo_root/.chezmoidata/packages.yaml" 'disposition: manual, reason: native macOS Korean input source'

# The macOS gpg-agent config names exactly the managed pinentry formula binary.
requires "$repo_root/private_dot_gnupg/.gpg-agent.darwin.conf" 'pinentry-program /opt/homebrew/bin/pinentry-mac'

# The encryption-status tools are read-only: no enablement verbs anywhere.
forbids "$repo_root/dot_local/bin/executable_encryption-status" 'fdesetup enable'
forbids "$repo_root/dot_local/bin/executable_encryption-status" 'fdesetup disable'
forbids "$repo_root/dot_local/bin/executable_encryption-status.ps1" 'Enable-BitLocker'
forbids "$repo_root/dot_local/bin/executable_encryption-status.ps1" 'Disable-BitLocker'
forbids "$repo_root/dot_local/bin/executable_encryption-status.ps1" 'manage-bde'
# ... and stay per-OS gated so neither leaks onto the wrong OS (or Linux).
requires "$repo_root/.chezmoiignore" '.local/bin/encryption-status'
requires "$repo_root/.chezmoiignore" '.local/bin/encryption-status.ps1'

# G0 closure stays exactly the three U4 gate-closing rows (chrome/cider/edge).
g0_rows=$(grep -Ec '^[[:space:]]+gateClosing: g0$' "$repo_root/.chezmoidata/packages.yaml")
[[ "$g0_rows" -eq 3 ]] || fail "expected exactly 3 gate-closing G0 rows, found $g0_rows"

printf '%s\n' 'native desktop outcome validation passed'
