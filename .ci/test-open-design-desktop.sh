#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
launcher=${1:-"$repo_root/dot_local/bin/executable_open-design"}
desktop_source=${2:-"$repo_root/dot_local/share/applications/open-design.desktop.tmpl"}
scratch_root=${XDG_RUNTIME_DIR:-"$HOME/.cache"}
mkdir -p -- "$scratch_root"
scratch=$(mktemp -d "$scratch_root/open-design-desktop.XXXXXX")
trap 'rm -rf -- "$scratch"' EXIT

test_home="$scratch/home"
fake_bin="$scratch/bin"
log="$scratch/commands.log"
mkdir -p "$fake_bin" "$test_home/.local/libexec/open-design" \
  "$test_home/.local/share/open-design/source/tools/pack/resources/linux"
cp "$launcher" "$test_home/.local/bin-open-design"
chmod 0755 "$test_home/.local/bin-open-design"

cat >"$test_home/.local/libexec/open-design/ensure-service" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'ensure-service %s\n' "$*" >>"$TEST_LOG"
printf 'runtime-output-that-launcher-must-discard\n'
printf 'ensure-service diagnostic\n' >&2
exit "${ENSURE_STATUS:-0}"
EOF
cat >"$fake_bin/google-chrome" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'google-chrome' >>"$TEST_LOG"
printf ' <%s>' "$@" >>"$TEST_LOG"
printf '\n' >>"$TEST_LOG"
EOF
cat >"$fake_bin/notify-send" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'notify-send' >>"$TEST_LOG"
printf ' <%s>' "$@" >>"$TEST_LOG"
printf '\n' >>"$TEST_LOG"
exit "${NOTIFY_STATUS:-0}"
EOF
chmod 0755 "$test_home/.local/libexec/open-design/ensure-service" \
  "$fake_bin/google-chrome" "$fake_bin/notify-send"
printf 'png' >"$test_home/.local/share/open-design/source/tools/pack/resources/linux/icon.png"

# Success waits through the shared web preflight, discards its runtime stdout,
# opens the exact app URL once, and does not notify.
: >"$log"
env HOME="$test_home" PATH="$fake_bin:/usr/bin:/bin" TEST_LOG="$log" \
  "$test_home/.local/bin-open-design" \
  >"$scratch/success.out" 2>"$scratch/success.err"
[[ ! -s "$scratch/success.out" ]]
grep -Fx 'ensure-service web' "$log"
grep -Fx 'google-chrome <--app=http://127.0.0.1:36947/>' "$log"
if grep -F 'notify-send' "$log"; then
  printf 'successful launch unexpectedly notified\n' >&2
  exit 1
fi

# Preflight failure preserves its non-zero status, never opens Chrome, emits
# exactly one desktop notification, and remains failed if notification itself
# is unavailable.
: >"$log"
set +e
env HOME="$test_home" PATH="$fake_bin:/usr/bin:/bin" TEST_LOG="$log" \
  ENSURE_STATUS=23 NOTIFY_STATUS=1 \
  "$test_home/.local/bin-open-design" \
  >"$scratch/failure.out" 2>"$scratch/failure.err"
status=$?
set -e
[[ $status -eq 23 ]]
[[ ! -s "$scratch/failure.out" ]]
grep -F 'ensure-service diagnostic' "$scratch/failure.err"
[[ $(grep -c '^notify-send' "$log") -eq 1 ]]
if grep -F 'google-chrome' "$log"; then
  printf 'failed preflight unexpectedly opened Chrome\n' >&2
  exit 1
fi
grep -F 'Open Design failed to start' "$log"
grep -F 'journalctl --user-unit open-design.service' "$log"

# Render the desktop entry against the isolated home and verify the freedesktop
# fields used by both KDE and GNOME discovery.
: >"$scratch/empty.toml"
env HOME="$test_home" chezmoi --config "$scratch/empty.toml" --source "$repo_root" \
  execute-template <"$desktop_source" >"$scratch/open-design.desktop"
grep -Fx '[Desktop Entry]' "$scratch/open-design.desktop"
grep -Fx 'Type=Application' "$scratch/open-design.desktop"
grep -Fx 'Name=Open Design' "$scratch/open-design.desktop"
grep -Fx "Exec=$test_home/.local/bin/open-design" "$scratch/open-design.desktop"
grep -Fx "Icon=$test_home/.local/share/open-design/source/tools/pack/resources/linux/icon.png" \
  "$scratch/open-design.desktop"
grep -Fx 'Terminal=false' "$scratch/open-design.desktop"
grep -Fx 'Categories=Graphics;Development;' "$scratch/open-design.desktop"

if command -v desktop-file-validate >/dev/null 2>&1; then
  desktop-file-validate "$scratch/open-design.desktop"
fi

printf 'open-design desktop tests passed\n'
