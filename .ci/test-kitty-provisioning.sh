#!/usr/bin/env bash
# .ci/test-kitty-provisioning.sh
#
# Verifies the render-level contract of the kitty provisioning migration:
# kitty is provisioned from the locked upstream bundle instead of the distro
# package, the managed launcher entry points at that bundle and claims no MIME
# types, and the managed config keeps the tab bar on the top edge using the 0.48
# key names the bundle expects.
#
# Never runs chezmoi apply, never downloads the kitty bundle, and never launches
# kitty — per the repo's non-deployment verification policy. The bundle download,
# checksum, symlink and prune behaviour is exercised by running the RENDERED
# script against a throwaway HOME, which is a local/manual step, not CI's job.

set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
scratch_root=${RUNNER_TEMP:-${XDG_RUNTIME_DIR:-"$HOME/.cache"}}
mkdir -p -- "$scratch_root"
scratch=$(mktemp -d "$scratch_root/kitty-provisioning.XXXXXX")
trap 'rm -rf -- "$scratch"' EXIT

: >"$scratch/empty.toml"
mkdir -p "$scratch/target" "$scratch/bin"

# Newline-free dummy secret, per the AGENTS.md stub recipe.
printf '#!/usr/bin/env bash\ncase "${1-}" in whoami) printf dummy@example.invalid;; *) printf dummy-secret;; esac\n' \
  >"$scratch/bin/op"
chmod 700 "$scratch/bin/op"

fail() {
  printf 'kitty-provisioning: %s\n' "$*" >&2
  exit 1
}

render() {
  env PATH="$scratch/bin:$PATH" \
    chezmoi --config "$scratch/empty.toml" --source "$repo_root" \
    --destination "$scratch/target" execute-template
}

has() { grep -qE -- "$1" "$2" || fail "$3 (in $2)"; }
lacks() { if grep -qE -- "$1" "$2"; then fail "$3 (in $2)"; fi; }

# --- the release lock carries kitty for both Linux architectures -------------
lock="$repo_root/.chezmoidata/releases.json"
[[ -s "$lock" ]] || fail "release lock missing"
command -v jq >/dev/null 2>&1 || fail "jq is required"
[[ "$(jq -r '.releases.tools.kitty.kind' "$lock")" == "githubRelease" ]] \
  || fail "kitty is not a githubRelease entry in the lock"
[[ "$(jq -r '.releases.tools.kitty.source' "$lock")" == "kovidgoyal/kitty" ]] \
  || fail "kitty lock entry has the wrong source"
for platform in linux-amd64 linux-arm64; do
  url=$(jq -r --arg p "$platform" '.releases.tools.kitty.artifacts[$p].url // ""' "$lock")
  sha=$(jq -r --arg p "$platform" '.releases.tools.kitty.artifacts[$p].sha256 // ""' "$lock")
  [[ "$url" == *.txz ]] || fail "kitty $platform artifact url is not a .txz: '$url'"
  [[ "$sha" =~ ^[0-9a-f]{64}$ ]] || fail "kitty $platform artifact has no sha256"
done
for platform in darwin-amd64 darwin-arm64 windows-amd64 windows-arm64; do
  [[ "$(jq -r --arg p "$platform" '.releases.tools.kitty.artifacts | has($p)' "$lock")" == "false" ]] \
    || fail "kitty lock unexpectedly targets $platform (upstream ships no bundle there)"
done

# --- the provisioning script renders with the locked artifact ---------------
render <"$repo_root/.chezmoiscripts/00-tools/run_onchange_before_kitty.sh.tmpl" >"$scratch/kitty.sh"
[[ -s "$scratch/kitty.sh" ]] || fail "provisioning script rendered empty"
lacks '\{\{' "$scratch/kitty.sh" "provisioning script has unresolved template markers"
has '^set -euo pipefail$' "$scratch/kitty.sh" "provisioning script does not set strict mode"
has '^VERSION="v[0-9]' "$scratch/kitty.sh" "provisioning script has no locked version"
has '^URL="https://github\.com/kovidgoyal/kitty/releases/download/.*\.txz"$' \
  "$scratch/kitty.sh" "provisioning script has no locked artifact url"
has '^SHA256="[0-9a-f]{64}"$' "$scratch/kitty.sh" "provisioning script has no locked checksum"
has 'sha256sum -c' "$scratch/kitty.sh" "provisioning script never verifies the checksum"
has 'fail "checksum mismatch' "$scratch/kitty.sh" "checksum mismatch is not a hard failure"

# The checksum must be verified BEFORE the archive is extracted.
checksum_line=$(grep -n 'sha256sum -c' "$scratch/kitty.sh" | head -1 | cut -d: -f1)
extract_line=$(grep -n 'tar -xJf' "$scratch/kitty.sh" | head -1 | cut -d: -f1)
[[ -n "$checksum_line" && -n "$extract_line" && "$checksum_line" -lt "$extract_line" ]] \
  || fail "checksum verification does not precede extraction ($checksum_line vs $extract_line)"

# The prune must skip symlinks so the `current` pointer cannot be deleted.
has '\[ -L "\$d" \]' "$scratch/kitty.sh" "prune loop does not skip symlinks"
# ~/.local/bin entry points go through `current`, so they survive a version bump.
has 'ln -sf "\$INSTALL_DIR/current/bin/kitty" "\$BIN_DIR/kitty"' \
  "$scratch/kitty.sh" "kitty is not linked into the bin dir through current"
has 'ln -sf "\$INSTALL_DIR/current/bin/kitten" "\$BIN_DIR/kitten"' \
  "$scratch/kitty.sh" "kitten is not linked into the bin dir through current"

# --- the launcher entry points at the bundle and claims no MIME types -------
render <"$repo_root/dot_local/share/applications/kitty.desktop.tmpl" >"$scratch/kitty.desktop"
lacks '\{\{' "$scratch/kitty.desktop" "launcher entry has unresolved template markers"
has '^Exec=/.*/\.local/share/kitty/current/bin/kitty$' \
  "$scratch/kitty.desktop" "launcher Exec is not an absolute path into the bundle"
has '^TryExec=/.*/\.local/share/kitty/current/bin/kitty$' \
  "$scratch/kitty.desktop" "launcher has no TryExec guard"
has '^Icon=/.*/\.local/share/kitty/current/share/icons/.*\.png$' \
  "$scratch/kitty.desktop" "launcher Icon is not an absolute path into the bundle"
has '^Categories=.*TerminalEmulator' "$scratch/kitty.desktop" "launcher is not categorised as a terminal"
lacks '^MimeType=' "$scratch/kitty.desktop" \
  "launcher registers MIME types, which would displace the desktop's file openers"

# --- the distro package no longer installs kitty ----------------------------
packages="$repo_root/.chezmoidata/packages.yaml"
lacks '^ +- kitty(\s|#|$)' "$packages" "a package group still installs kitty"
xdg_rows=$(grep -cE '^ +- xdg-terminal-exec' "$packages" || true)
[[ "$xdg_rows" -eq 3 ]] \
  || fail "expected 3 xdg-terminal-exec rows (the provider entry still needs it), found $xdg_rows"
has 'dnf remove kitty' "$packages" "the one-time Fedora uninstall is not documented"
has 'apt remove kitty' "$packages" "the one-time Ubuntu uninstall is not documented"

# --- host gating lives in .chezmoiignore ------------------------------------
# Block membership is asserted, not just line presence: a kitty line that drifted
# out of its gated block would still satisfy a bare count. Evaluating the gate
# predicates themselves needs a forged fact cache, which this harness does not
# build — that residual is covered by the plan's operator check, not here.
ignore="$repo_root/.chezmoiignore"
block_of() {
  # Print the gate expression guarding the block that contains $1's first match.
  awk -v needle="$1" '
    /^\{\{- if/ { gate = $0 }
    index($0, needle) && !found { print gate; found = 1 }
  ' "$ignore"
}
desktop_gate=$(block_of '.chezmoiscripts/00-tools/*kitty.sh')
[[ "$desktop_gate" == *'ne .chezmoi.os "linux"'* && "$desktop_gate" == *'$f.desktop'* ]] \
  || fail "the provisioner's first ignore entry is not inside the OS/desktop gate: '$desktop_gate'"
script_skips=$(grep -cF '.chezmoiscripts/00-tools/*kitty.sh' "$ignore" || true)
launcher_skips=$(grep -cF '.local/share/applications/kitty.desktop' "$ignore" || true)
[[ "$script_skips" -eq 2 ]] \
  || fail "expected the provisioner skipped in 2 gated blocks (no-desktop, container), found $script_skips"
[[ "$launcher_skips" -eq 2 ]] \
  || fail "expected the launcher skipped in 2 gated blocks (no-desktop, container), found $launcher_skips"
# The second occurrence of each must sit under the container fact.
container_block=$(awk '/^\{\{- if \$f\.container \}\}/{f=1} f{print} /^\{\{- end \}\}/{if(f)exit}' "$ignore")
printf '%s\n' "$container_block" | grep -qF '.chezmoiscripts/00-tools/*kitty.sh' \
  || fail "the provisioner is not skipped inside the container block"
printf '%s\n' "$container_block" | grep -qF '.local/share/applications/kitty.desktop' \
  || fail "the launcher is not skipped inside the container block"
render <"$ignore" >"$scratch/ignore.rendered"
lacks '\{\{' "$scratch/ignore.rendered" ".chezmoiignore has unresolved template markers"
# --- the managed config keeps the top-edge tab bar ---------------------------
render <"$repo_root/dot_config/kitty/kitty.conf.tmpl" >"$scratch/kitty.conf"
lacks '\{\{' "$scratch/kitty.conf" "kitty.conf has unresolved template markers"
has '^tab_bar_edge top$' "$scratch/kitty.conf" "tab bar is not on the top edge"
has '^tab_bar_min_tabs 1$' "$scratch/kitty.conf" "tab bar is not shown for a single tab"
has '^initial_window_width +128c$' "$scratch/kitty.conf" "managed window width changed"
has '^tab_bar_style powerline$' "$scratch/kitty.conf" "powerline tab bar style was lost"
has '^tab_powerline_style slanted$' "$scratch/kitty.conf" "slanted powerline separators were lost"
has '^strip_trailing_spaces smart$' "$scratch/kitty.conf" "renamed trailing-space key not applied"
lacks '^tab_bar_edge (left|right|bottom)$' "$scratch/kitty.conf" \
  "a second tab_bar_edge line would win over the top edge"
lacks '^strip_trailing_space ' "$scratch/kitty.conf" \
  "the pre-0.48 singular trailing-space key is still present"
# Plan 004's chrome and font coupling must be untouched.
has '^hide_window_decorations no$' "$scratch/kitty.conf" "chrome setting changed"
has '^font_family .+$' "$scratch/kitty.conf" "font family no longer renders from fonts.yaml"
has '^font_size [0-9]+$' "$scratch/kitty.conf" "font size no longer renders from fonts.yaml"

printf 'kitty-provisioning: all checks passed\n'
