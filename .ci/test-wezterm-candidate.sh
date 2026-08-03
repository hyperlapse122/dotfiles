#!/usr/bin/env bash
# .ci/test-wezterm-candidate.sh
#
# Hermetic contract for the G1 WezTerm CANDIDATE (U11 of
# docs/plans/2026-08-03-004-feat-cross-platform-workstation-parity-plan.md):
# the candidate exists as managed source with explicit per-OS architecture
# dispositions and an opt-in launch path, while Kitty stays the authoritative,
# default terminal until protected G1b evidence opens.
#
# Proves, without a GUI and without launching wezterm:
#   1. packages.yaml carries the weztermTerminal row with exact dispositions —
#      Fedora amd64/arm64 UNRESOLVED (the precise G1a blocker is recorded),
#      Windows winget-managed with explicit arm64 x64 emulation, macOS
#      Homebrew-cask-managed native arm64;
#   2. no duplicate ownership authority — the candidate is NOT in the release
#      lock, the registry, chezmoi externals, or mise (Windows/macOS are
#      winget/Homebrew owned; Fedora has no lockable artifact);
#   3. Kitty stays authoritative and default: kitty sources untouched, no
#      wezterm xdg-terminals provider entry, KDE TerminalApplication stays
#      kitty, and the tmux image pair (allow-passthrough +
#      PI_FORCE_IMAGE_PROTOCOL=kitty) is intact;
#   4. the candidate config renders (font from fonts.yaml, Kitty graphics on)
#      and the opt-in launcher claims no default and no MIME types;
#   5. host gating keeps the launcher off non-desktop and container targets;
#   6. the tmux transport the candidate will rely on: passthrough on/off
#      negative pair, plus split/unsplit/resize/redraw re-emission of pane
#      bytes to an attached client.
#
# Pixel evidence (an actual image drawn by WezTerm surviving scroll, redraw,
# resize and split, on real Fedora/Windows/macOS) is G1b PROTECTED-DEVICE
# INPUT. This fixture never fabricates it and never asserts placeholder
# survival locally — stable WezTerm lacking Kitty Unicode placeholders IS the
# recorded G1a blocker, so a local placeholder "proof" would be a fake. The
# final section registers an optional device record via
# WEZTERM_VISUAL_EVIDENCE without taking a verdict on it (that authority
# belongs to the protected device-evidence validator).
#
# Never runs chezmoi apply, never downloads or launches wezterm, and never
# addresses the default tmux socket — isolated servers live on scratch-scoped
# -S sockets, per the repo's non-deployment verification policy.

set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
scratch_root=${RUNNER_TEMP:-${XDG_RUNTIME_DIR:-"$HOME/.cache"}}
mkdir -p -- "$scratch_root"
scratch=$(mktemp -d "$scratch_root/wezterm-candidate.XXXXXX")
sock="$scratch/sock"

cleanup() {
  tmux -S "$sock" kill-server 2>/dev/null || true
  tmux -S "${sock}-off" kill-server 2>/dev/null || true
  tmux -S "${sock}-redraw" kill-server 2>/dev/null || true
  rm -rf -- "$scratch"
}
trap cleanup EXIT

: >"$scratch/empty.toml"
mkdir -p "$scratch/target" "$scratch/bin"

# Newline-free dummy secret, per the AGENTS.md stub recipe.
printf '#!/usr/bin/env bash\ncase "${1-}" in whoami) printf dummy@example.invalid;; *) printf dummy-secret;; esac\n' \
  >"$scratch/bin/op"
chmod 700 "$scratch/bin/op"

fail() {
  printf 'wezterm-candidate: %s\n' "$*" >&2
  exit 1
}

render() {
  env PATH="$scratch/bin:$PATH" \
    chezmoi --config "$scratch/empty.toml" --source "$repo_root" \
    --destination "$scratch/target" execute-template
}

has() { grep -qE -- "$1" "$2" || fail "$3 (in $2)"; }
lacks() { if grep -qE -- "$1" "$2"; then fail "$3 (in $2)"; fi; }

command -v jq >/dev/null 2>&1 || fail "jq is required"

# --- 1. capability dispositions ---------------------------------------------
printf '%s' '{{ .packages.authority.capabilities | toJson }}' | render >"$scratch/capabilities.json"

wz=$(jq -c '.[] | select(.id == "weztermTerminal")' "$scratch/capabilities.json")
[ -n "$wz" ] || fail "packages.yaml has no weztermTerminal capability row"
[ "$(jq -r '.sentinel' <<<"$wz")" = "wezterm" ] || fail "weztermTerminal sentinel is not wezterm"

# Fedora: BOTH architectures unresolved, and the reason records the precise
# G1a blocker (no placeholder support in stable, no current-Fedora RPM, no
# aarch64 RPM) — absence cannot masquerade as support.
[ "$(jq -r '.fedora.disposition' <<<"$wz")" = "unresolved" ] \
  || fail "weztermTerminal fedora disposition is not unresolved — G1a is closed"
[ "$(jq -r '.fedora.architectures.amd64' <<<"$wz")" = "unresolved" ] \
  || fail "weztermTerminal fedora amd64 is not explicitly unresolved"
[ "$(jq -r '.fedora.architectures.arm64' <<<"$wz")" = "unresolved" ] \
  || fail "weztermTerminal fedora arm64 is not explicitly unresolved"
reason=$(jq -r '.fedora.reason' <<<"$wz")
case "$reason" in
  *20240203-110809-5046fc22*placeholder*aarch64*) ;;
  *) fail "weztermTerminal fedora reason does not record the precise G1a blocker: $reason" ;;
esac

# Windows: winget-owned, x64 native, arm64 explicitly emulated (KTD13 —
# emulation is a valid Windows resolution, never a Linux one).
[ "$(jq -r '.windows.owner' <<<"$wz")" = "winget" ] || fail "weztermTerminal windows owner is not winget"
[ "$(jq -r '.windows.identifier' <<<"$wz")" = "wez.wezterm" ] \
  || fail "weztermTerminal windows identifier is not wez.wezterm"
[ "$(jq -r '.windows.source' <<<"$wz")" = "winget" ] \
  || fail "weztermTerminal windows source is not the predefined winget source"
[ "$(jq -r '.windows.scope' <<<"$wz")" = "machine" ] || fail "weztermTerminal windows scope is not machine"
[ "$(jq -r '.windows.elevation' <<<"$wz")" = "admin" ] || fail "weztermTerminal windows elevation is not admin"
[ "$(jq -r '.windows.architectures.amd64' <<<"$wz")" = "native" ] \
  || fail "weztermTerminal windows amd64 is not native"
[ "$(jq -r '.windows.architectures.arm64' <<<"$wz")" = "emulated" ] \
  || fail "weztermTerminal windows arm64 is not explicitly emulated"
[ "$(jq -r '.windows.emulation' <<<"$wz")" = "x64" ] \
  || fail "weztermTerminal windows arm64 emulation is not declared x64"

# macOS: Homebrew-cask-owned, native arm64.
[ "$(jq -r '.macos.owner' <<<"$wz")" = "homebrew" ] || fail "weztermTerminal macos owner is not homebrew"
[ "$(jq -r '.macos.kind' <<<"$wz")" = "cask" ] || fail "weztermTerminal macos kind is not cask"
[ "$(jq -r '.macos.identifier' <<<"$wz")" = "wezterm" ] || fail "weztermTerminal macos identifier is not wezterm"
[ "$(jq -r '.macos.source' <<<"$wz")" = "homebrewCask" ] \
  || fail "weztermTerminal macos source is not homebrewCask"
[ "$(jq -r '.macos.architectures.arm64' <<<"$wz")" = "native" ] \
  || fail "weztermTerminal macos arm64 is not native"

# --- 2. no duplicate ownership authority -------------------------------------
# Windows/macOS are winget/Homebrew owned; a release-lock, external or mise
# entry beside them would be a second authority for the same capability, and
# Fedora has no lockable artifact while G1a is closed.
lock="$repo_root/.chezmoidata/releases.json"
[ -s "$lock" ] || fail "release lock missing"
[ "$(jq -r '.releases.tools | has("wezterm")' "$lock")" = "false" ] \
  || fail "wezterm entered the release lock — duplicate authority beside winget/Homebrew"
lacks '^  ("wezterm"|wezterm): \{' "$repo_root/packages/release-lock/src/registry.ts" \
  "wezterm entered the release-lock registry — duplicate authority beside winget/Homebrew"
if grep -qE '^\[wezterm\]' "$repo_root"/.chezmoiexternals/*.toml; then
  fail "wezterm entered chezmoi externals — duplicate authority beside winget/Homebrew"
fi
lacks '^wezterm[ =]' "$repo_root/dot_config/mise/config.toml" \
  "wezterm entered mise — duplicate authority beside winget/Homebrew"

# --- 3. Kitty stays authoritative and default --------------------------------
kt=$(jq -c '.[] | select(.id == "kittyTerminal")' "$scratch/capabilities.json")
[ -n "$kt" ] || fail "kittyTerminal capability row is gone — Kitty must stay managed until G1b"
[ "$(jq -r '.fedora.disposition' <<<"$kt")" = "managed" ] \
  || fail "kittyTerminal fedora is no longer managed — Kitty must stay authoritative until G1b"
[ "$(jq -r '.fedora.owner' <<<"$kt")" = "releaseLock" ] \
  || fail "kittyTerminal fedora owner changed — Kitty must stay release-lock owned until G1b"

for f in \
  dot_config/kitty/kitty.conf.tmpl \
  .chezmoiscripts/00-tools/run_onchange_before_kitty.sh.tmpl \
  dot_local/share/applications/kitty.desktop.tmpl \
  dot_local/share/xdg-terminals/kitty.desktop; do
  [ -f "$repo_root/$f" ] || fail "kitty source $f is gone — Kitty stays fully managed until G1b"
done

# The candidate must not register a default-terminal provider: xdg-terminals/
# is the resolver path that makes kitty the default, and KDE's
# TerminalApplication must keep pointing at kitty.
if ls "$repo_root"/dot_local/share/xdg-terminals/ | grep -qi wezterm; then
  fail "wezterm entered dot_local/share/xdg-terminals — that path resolves the DEFAULT terminal"
fi
has 'key: TerminalApplication, type: string, value: kitty' "$repo_root/.chezmoidata/kde.yaml" \
  "KDE default terminal no longer points at kitty"

# The tmux image pair is structural until G1b (KTD14): passthrough carries
# omp's wrapped graphics escape, the forced protocol turns on the placeholders
# that let tmux own the image cells.
tmux_conf="$repo_root/dot_config/tmux/tmux.conf"
has '^set -g allow-passthrough on$' "$tmux_conf" "tmux allow-passthrough pair member changed"
has '^set-environment -g PI_FORCE_IMAGE_PROTOCOL kitty$' "$tmux_conf" \
  "tmux forced-protocol pair member changed"
lacks 'allow-passthrough all' "$tmux_conf" "tmux passthrough was widened to all"

# --- 4. candidate config renders ---------------------------------------------
render <"$repo_root/dot_config/wezterm/wezterm.lua.tmpl" >"$scratch/wezterm.lua"
[ -s "$scratch/wezterm.lua" ] || fail "wezterm.lua rendered empty"
lacks '\{\{' "$scratch/wezterm.lua" "wezterm.lua has unresolved template markers"
family=$(printf '%s' '{{ .fonts.families.mono }}' | render)
size=$(printf '%s' '{{ .fonts.sizes.terminal }}' | render)
grep -qF "config.font = wezterm.font(\"$family\")" "$scratch/wezterm.lua" \
  || fail "wezterm.lua no longer renders the shared mono family from fonts.yaml"
has "^config\.font_size = ${size}$" "$scratch/wezterm.lua" \
  "wezterm.lua no longer renders the terminal size from fonts.yaml"
has '^config\.enable_kitty_graphics = true$' "$scratch/wezterm.lua" \
  "wezterm.lua lost Kitty graphics protocol support"
has '^config\.scrollback_lines = 10000$' "$scratch/wezterm.lua" "wezterm.lua scrollback changed"
has '^config\.check_for_updates = false$' "$scratch/wezterm.lua" "wezterm.lua re-enabled update checks"
has '^return config$' "$scratch/wezterm.lua" "wezterm.lua does not return the config table"
# The config must not pretend stable wezterm has Kitty Unicode placeholders —
# their absence is the G1a blocker, not a setting.
lacks '^config\.[A-Za-z_]*placeholder' "$scratch/wezterm.lua" \
  "wezterm.lua sets a placeholder option that stable wezterm does not implement"

# Lua syntax check where an interpreter exists; CI images generally ship
# neither, and the render assertions above are the committed contract.
if command -v luac >/dev/null 2>&1; then
  luac -p "$scratch/wezterm.lua" || fail "wezterm.lua fails luac syntax check"
elif command -v lua >/dev/null 2>&1; then
  lua -e "assert(loadfile('$scratch/wezterm.lua'))" || fail "wezterm.lua fails lua syntax check"
else
  printf 'wezterm-candidate: no lua interpreter; wezterm.lua syntax check skipped (render assertions applied)\n'
fi

# --- 5. opt-in launcher -------------------------------------------------------
launcher="$repo_root/dot_local/share/applications/wezterm.desktop"
[ -f "$launcher" ] || fail "candidate launcher missing"
has '^Name=WezTerm \(candidate\)$' "$launcher" "launcher name does not mark the candidate"
has '^Exec=wezterm start --cwd \.$' "$launcher" "launcher Exec is not the bare PATH-resolved wezterm"
has '^TryExec=wezterm$' "$launcher" "launcher has no TryExec guard against a missing binary"
has '^Categories=.*TerminalEmulator' "$launcher" "launcher is not categorised as a terminal"
lacks '^MimeType=' "$launcher" \
  "launcher registers MIME types, which would displace the desktop's file openers"
lacks '^Exec=/' "$launcher" \
  "launcher points at an absolute path, but this repo has no managed wezterm install location"

# --- 6. host gating lives in .chezmoiignore -----------------------------------
# Block membership is structural: each wezterm launcher entry must sit on the
# line directly after the kitty launcher entry, whose own block membership
# (no-desktop block first, container block second) test-kitty-provisioning.sh
# already proves.
ignore="$repo_root/.chezmoiignore"
mapfile -t kt_lines < <(grep -nF '.local/share/applications/kitty.desktop' "$ignore" | cut -d: -f1)
mapfile -t wz_lines < <(grep -nF '.local/share/applications/wezterm.desktop' "$ignore" | cut -d: -f1)
[ "${#wz_lines[@]}" -eq 2 ] \
  || fail "expected the candidate launcher skipped in 2 gated blocks (no-desktop, container), found ${#wz_lines[@]}"
[ "${#kt_lines[@]}" -eq 2 ] || fail "kitty launcher gating drifted — expected 2 entries"
for i in 0 1; do
  [ "$((kt_lines[i] + 1))" = "${wz_lines[i]}" ] \
    || fail "candidate launcher entry $((i + 1)) is not inside the same gated block as the kitty entry"
done
render <"$ignore" >"$scratch/ignore.rendered"
lacks '\{\{' "$scratch/ignore.rendered" ".chezmoiignore has unresolved template markers"

# --- 7. tmux transport: passthrough pair + redraw contract --------------------
command -v tmux >/dev/null 2>&1 || fail 'tmux not found on PATH'

# Record the default socket's value up front so the isolation check at the end
# can prove this run never touched it. A missing default server is fine.
default_before=$(tmux show -gv allow-passthrough 2>/dev/null || echo '<no-default-server>')

# The candidate relies on the SAME managed pair as kitty (KTD14): passthrough
# carries the wrapped graphics escape, and the forced kitty protocol is what
# would turn placeholders on for a terminal that implements them.
tmux -S "$sock" -f "$tmux_conf" new-session -d -s opts 'sleep 120' \
  || fail 'the managed tmux config did not load on an isolated server'
[ "$(tmux -S "$sock" show -gv allow-passthrough 2>/dev/null)" = 'on' ] \
  || fail 'managed tmux server lost allow-passthrough=on'
# The forced protocol must reach a real pane process; a session-environment
# listing does not show a globally-set variable.
pane_cmd=$(printf 'printf %%s "$PI_FORCE_IMAGE_PROTOCOL" > %q/pane-env; sleep 5' "$scratch")
tmux -S "$sock" new-session -d -s envA "$pane_cmd" \
  || fail 'could not start the pane-environment probe session'
for _ in $(seq 1 50); do [ -s "$scratch/pane-env" ] && break; sleep 0.1; done
got=$(cat "$scratch/pane-env" 2>/dev/null || true)
[ "$got" = 'kitty' ] || fail "a pane saw PI_FORCE_IMAGE_PROTOCOL='$got', expected 'kitty'"
tmux -S "$sock" kill-server 2>/dev/null || true

# tmux only forwards a passthrough payload to an ATTACHED client, so the
# transport and redraw cases need a pty. util-linux script(1) covers CI
# runners; unbuffer (expect) covers hosts that ship it instead.
pty_provider=''
if command -v script >/dev/null 2>&1; then
  pty_provider=script
elif command -v unbuffer >/dev/null 2>&1; then
  pty_provider=unbuffer
fi

if [ -z "$pty_provider" ]; then
  if [ -n "${CI:-}" ]; then
    fail 'no pty provider in CI (need script(1) or unbuffer); the transport and redraw cases cannot run and must not be skipped'
  fi
  printf 'wezterm-candidate: dispositions, ownership, kitty-authority, config, launcher and gating OK\n'
  printf 'wezterm-candidate: SKIP transport/redraw cases locally — no pty provider (need script(1) or unbuffer)\n'
  exit 0
fi

wrapped="WZWRAPPED$$"
bare="WZBARE$$"
fidelity="WZFIDELITY$$"
# The literal bytes the emitter writes for the fidelity probe: ESC [ 1 m <text>.
sgr_marker=$(printf '\033[1m%s' "$fidelity")

emit="$scratch/emit.sh"
cat >"$emit" <<EOF
#!/usr/bin/env bash
# \$1 = the socket of the server running this pane.
# allow-passthrough=on forwards ONLY from a visible pane, so emitting before
# the client has attached would lose the payload for a reason unrelated to the
# setting. Wait for a client, then let it paint.
for _ in \$(seq 1 100); do
  case "\$(tmux -S "\$1" list-clients -F x 2>/dev/null)" in
    x*) break ;;
  esac
  sleep 0.1
done
sleep 0.5
# Three probes, each isolating one layer (same shapes as
# test-tmux-kitty-passthrough.sh):
printf '\033[1m%s\033[0m' '$fidelity'  # raw SGR — capture is byte-faithful
printf '\033_G%s\033\\\\' '$bare'      # bare Kitty APC — client receives APCs
printf '\033Ptmux;\033\033_G%s\033\033\\\\\033\\\\' '$wrapped'  # DCS-wrapped — the gated form omp emits
sleep 1
EOF
chmod 700 "$emit"

# A config that loads the managed file and then closes the passthrough gate:
# the ONLY difference between the two runs is the setting under test.
printf 'source-file %s\nset -g allow-passthrough off\n' "$tmux_conf" >"$scratch/off.conf"

pty_run() { # $1 = socket, $2 = config, $3 = capture path
  local run_sock=$1 run_conf=$2 cap=$3 pane_cmd
  pane_cmd=$(printf '%q %q' "$emit" "$run_sock")
  case "$pty_provider" in
    script)
      local cmd
      cmd=$(printf 'tmux -S %q -f %q new-session %q' "$run_sock" "$run_conf" "$pane_cmd")
      TERM=xterm-256color script -q -e -c "$cmd" "$cap" >/dev/null 2>&1 || true
      ;;
    unbuffer)
      TERM=xterm-256color unbuffer \
        tmux -S "$run_sock" -f "$run_conf" new-session "$pane_cmd" >"$cap" 2>&1 || true
      ;;
  esac
  tmux -S "$run_sock" kill-server 2>/dev/null || true
}

# Fixed-string match, always a number (see test-tmux-kitty-passthrough.sh for
# why bare grep -c is unsafe here).
count() {
  local n
  n=$(LC_ALL=C grep -acF -- "$1" "$2" 2>/dev/null || true)
  case "$n" in
    ''|*[!0-9]*) printf '0' ;;
    *) printf '%s' "$n" ;;
  esac
}

capture_case() { # $1 = label, $2 = socket, $3 = config, $4 = capture path
  pty_run "$2" "$3" "$4"
  [ -s "$4" ] || fail "the $pty_provider capture for the $1 case is empty; the pty run produced nothing"
  [ "$(count "$sgr_marker" "$4")" != '0' ] \
    || fail "the $pty_provider capture for the $1 case dropped the raw SGR marker; the capture path is not byte-faithful"
  [ "$(count "$bare" "$4")" != '0' ] \
    || fail "the $1 case never delivered a BARE Kitty APC, which tmux forwards regardless of allow-passthrough; this environment cannot carry APC bytes, so the wrapped-payload verdict would be meaningless"
}

# Passthrough ON: the wrapped graphics payload must reach the client.
capture_case 'passthrough-on' "$sock" "$tmux_conf" "$scratch/cap-on"
[ "$(count "$wrapped" "$scratch/cap-on")" != '0' ] \
  || fail 'passthrough is on but the wrapped Kitty graphics payload never reached the client'

# Passthrough OFF: the negative case that proves the setting is the cause —
# the bare probe still arrives, only the gated form disappears.
capture_case 'passthrough-off' "${sock}-off" "$scratch/off.conf" "$scratch/cap-off"
[ "$(count "$wrapped" "$scratch/cap-off")" = '0' ] \
  || fail 'passthrough is off but the wrapped Kitty graphics payload still reached the client'

# --- 7b. split/unsplit/resize/redraw command path -----------------------------
# Exercise AE4's tmux-level structural operations against an attached client.
# tmux may preserve unchanged cells without re-emitting their original bytes,
# so byte-count growth is not a valid image-retention oracle. Protected device
# evidence owns the pixel-retention verdict.
redraw_marker="WZREDRAW$$"
redraw_pane="$scratch/redraw-pane.sh"
cat >"$redraw_pane" <<EOF
#!/usr/bin/env bash
printf '\033[1m%s\033[0m\n' '$redraw_marker'
sleep 60
EOF
chmod 700 "$redraw_pane"
redraw_sgr=$(printf '\033[1m%s' "$redraw_marker")

rsock="${sock}-redraw"
rcap="$scratch/cap-redraw"
pane_cmd=$(printf '%q' "$redraw_pane")
case "$pty_provider" in
  script)
    cmd=$(printf 'tmux -S %q -f %q new-session -s redraw %q' "$rsock" "$tmux_conf" "$pane_cmd")
    TERM=xterm-256color script -q -e -c "$cmd" "$rcap" >/dev/null 2>&1 &
    ;;
  unbuffer)
    TERM=xterm-256color unbuffer \
      tmux -S "$rsock" -f "$tmux_conf" new-session -s redraw "$pane_cmd" >"$rcap" 2>&1 &
    ;;
esac
cap_pid=$!

# Wait for the client to attach and the pane to paint.
for _ in $(seq 1 100); do
  case "$(tmux -S "$rsock" list-clients -F x 2>/dev/null)" in
    x*) break ;;
  esac
  sleep 0.1
done
sleep 0.5

panes() { tmux -S "$rsock" list-panes -t redraw -F x 2>/dev/null | wc -l; }

# split -> the pane set really grows, and the split triggers a redraw
tmux -S "$rsock" split-window -d -t redraw 'sleep 60' || fail 'split-window failed on the redraw server'
sleep 0.4
[ "$(panes)" = '2' ] || fail "split did not produce 2 panes (got $(panes))"

# resize -> the new pane really takes the requested height
tmux -S "$rsock" resize-pane -t redraw:0.1 -y 5 || fail 'resize-pane failed on the redraw server'
sleep 0.4
height=$(tmux -S "$rsock" display-message -p -t redraw:0.1 '#{pane_height}')
[ "$height" = '5' ] || fail "resize did not take: pane height is $height, expected 5"

# unsplit -> back to one pane
tmux -S "$rsock" kill-pane -t redraw:0.1 || fail 'kill-pane (unsplit) failed on the redraw server'
sleep 0.4
[ "$(panes)" = '1' ] || fail "unsplit did not return to 1 pane (got $(panes))"

# explicit redraw -> the command path must remain valid for the attached client
tmux -S "$rsock" refresh-client || fail 'refresh-client failed on the redraw server'
sleep 0.6

tmux -S "$rsock" kill-server 2>/dev/null || true
wait "$cap_pid" 2>/dev/null || true

[ -s "$rcap" ] || fail 'the redraw capture is empty; the pty run produced nothing'
[ "$(count "$redraw_sgr" "$rcap")" != '0' ] \
  || fail 'the redraw capture dropped the raw SGR marker; the capture path is not byte-faithful'

# --- 8. isolation --------------------------------------------------------------
default_after=$(tmux show -gv allow-passthrough 2>/dev/null || echo '<no-default-server>')
[ "$default_before" = "$default_after" ] \
  || fail "this run changed the default socket's allow-passthrough ($default_before -> $default_after)"

# --- 9. pixel evidence is protected-device input, never fabricated ------------
if [ -n "${WEZTERM_VISUAL_EVIDENCE:-}" ]; then
  [ -s "$WEZTERM_VISUAL_EVIDENCE" ] \
    || fail "WEZTERM_VISUAL_EVIDENCE points at a missing or empty record: $WEZTERM_VISUAL_EVIDENCE"
  # Shape-check against the CANONICAL device-evidence record only
  # (.ci/device-evidence.schema.json): this fixture invents no schema of its
  # own, and the G1b verdict stays with the protected device-evidence
  # validator.
  jq -e '.schemaVersion and .device.os and .device.arch and .measurements' \
    "$WEZTERM_VISUAL_EVIDENCE" >/dev/null \
    || fail 'visual record is not a canonical device-evidence record (needs schemaVersion, device.os, device.arch, measurements)'
  case "$(jq -r '.device.os' "$WEZTERM_VISUAL_EVIDENCE")" in
    fedora | windows | macos) ;;
    *) fail "visual record names an unsupported OS leg: $(jq -r '.device.os' "$WEZTERM_VISUAL_EVIDENCE")" ;;
  esac
  printf 'wezterm-candidate: visual record registered (%s); the G1b verdict stays with the protected device-evidence validator, not this fixture\n' \
    "$WEZTERM_VISUAL_EVIDENCE"
else
  printf 'wezterm-candidate: pixel legs (inline image through scroll/redraw/resize/split on real Fedora, Windows and macOS) are G1b protected-device input; set WEZTERM_VISUAL_EVIDENCE to register a device record — this fixture never fabricates pixel proof\n'
fi

printf 'wezterm-candidate: all checks passed\n'
