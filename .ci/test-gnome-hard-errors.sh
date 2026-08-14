#!/usr/bin/env bash
set -euo pipefail

shortcut=${1:?usage: test-gnome-hard-errors.sh SHORTCUT_SCRIPT IBUS_SCRIPT}
ibus=${2:?usage: test-gnome-hard-errors.sh SHORTCUT_SCRIPT IBUS_SCRIPT}
scratch_root=${XDG_RUNTIME_DIR:-"$HOME/.cache"}
scratch=$(mktemp -d "$scratch_root/gnome-hard-errors-test.XXXXXX")
trap 'rm -rf -- "$scratch"' EXIT

prepare_script() {
  local source=$1 destination=$2
  sed \
    -e 's/^[[:space:]]*FACT_DESKTOP=.*/  FACT_DESKTOP=gnome/' \
    -e "s|^COMMAND=.*$|COMMAND=\"$fake_bin/1password\"|" \
    "$source" >"$destination"
  chmod 0755 "$destination"
}

fake_bin="$scratch/bin"
mkdir -p "$fake_bin"
cat >"$fake_bin/gsettings" <<'EOF'
#!/usr/bin/env bash
if [[ ${GNOME_GSETTINGS_MODE:-} == get-fail && ${1:-} == get ]]; then
  exit 41
fi
if [[ ${1:-} == get ]]; then
  case "${3:-}" in
    custom-keybindings) printf '%s\n' "${GNOME_GSETTINGS_VALUE:-[]}" ;;
    sources) printf '%s\n' "${GNOME_GSETTINGS_VALUE:-[]}" ;;
    *) printf "''\n" ;;
  esac
fi
EOF
chmod 0755 "$fake_bin/gsettings"
cat >"$fake_bin/1password" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod 0755 "$fake_bin/1password"

shortcut_script="$scratch/shortcut.sh"
ibus_script="$scratch/ibus.sh"
prepare_script "$shortcut" "$shortcut_script"
prepare_script "$ibus" "$ibus_script"

assert_hard_failure() {
  local label=$1 script=$2 mode=$3 value=$4 diagnostic=$5
  local home="$scratch/$label/home"
  mkdir -p "$home"
  set +e
  env HOME="$home" PATH="$fake_bin:$PATH" DBUS_SESSION_BUS_ADDRESS='unix:path=/fixture/bus' \
    GNOME_GSETTINGS_MODE="$mode" GNOME_GSETTINGS_VALUE="$value" bash "$script" \
    >"$scratch/$label.stdout" 2>"$scratch/$label.stderr"
  status=$?
  set -e
  [[ $status -ne 0 ]] || { printf '%s unexpectedly succeeded\n' "$label" >&2; return 1; }
  grep -F "$diagnostic" "$scratch/$label.stderr" >/dev/null
  if grep -E 'Recorded as done|nothing to do|not applicable' \
    "$scratch/$label.stdout" "$scratch/$label.stderr" >/dev/null; then
    printf '%s emitted a declared skip/success marker\n' "$label" >&2
    return 1
  fi
  if compgen -G "$home/.local/state/chezmoi/skips/*" >/dev/null || \
     compgen -G "$home/.local/state/chezmoi/gnome-*" >/dev/null; then
    printf '%s created a skip or success state marker\n' "$label" >&2
    return 1
  fi
}

assert_hard_failure shortcut-gsettings "$shortcut_script" get-fail '[]' \
  'config-gnome-1password-shortcut: failed to read custom-keybindings with gsettings'
assert_hard_failure shortcut-parser "$shortcut_script" success 'not valid gvariant' \
  'config-gnome-1password-shortcut: custom-keybindings is not valid GVariant string-list text'
assert_hard_failure ibus-gsettings "$ibus_script" get-fail '[]' \
  'config-gnome-remove-ibus-source: failed to read input sources with gsettings'
assert_hard_failure ibus-parser "$ibus_script" success 'not valid gvariant' \
  'config-gnome-remove-ibus-source: input sources are not valid GVariant tuple-list text'

printf 'GNOME hard-error boundary tests passed\n'
