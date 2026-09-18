#!/usr/bin/env bash
# GnuPG config render and reload gate (KTD6, KTD8, KTD10, U6).
#
# Asserts:
# 1. gpg-agent.conf renders on linux (gnome, kde, none) and darwin with pinentry-program
#    pointing to ~/.gnupg/pinentry-card and no direct desktop pinentry paths remaining.
# 2. scdaemon.conf deploys to .gnupg/scdaemon.conf in the scratch target tree with
#    disable-ccid and pcsc-shared citing KTD8.
# 3. Rendered reload script with a missing delegate path exits non-zero naming the delegate,
#    before any gpgconf call.
# 4. Darwin variant of the reload script with failing xcode-select exits non-zero naming
#    xcode-select --install, before any gpgconf call.
# 5. Rendered reload script contains a fingerprint line for every private_dot_gnupg/ source
#    file, passes bash -n, and with a fake gpgconf on PATH logs --reload gpg-agent and
#    --reload scdaemon.
# 6. Rendered reload script under real gpgconf with scratch GNUPGHOME and no agent exits 0.
# 7. Container variant of .chezmoiignore ignores .chezmoiscripts/80-keys/reload-gpg-agent.sh
#    (eligible on host).
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=.ci/lib/render-gate-helpers.sh
source "$repo_root/.ci/lib/render-gate-helpers.sh"
# shellcheck source=.ci/lib/render-scratch.sh
source "$repo_root/.ci/lib/render-scratch.sh"
# shellcheck source=.ci/lib/source-root.sh
source "$repo_root/.ci/lib/source-root.sh"
source_root=$(resolve_source_root "$repo_root")

setup_render_scratch gnupg-config-render
mkdir -p "$scratch/home"

fail() { printf 'test-gnupg-config-render: FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'test-gnupg-config-render: ok - %s\n' "$*"; }

chezmoi_bin=$(type -P chezmoi) || fail 'chezmoi is required on PATH'
command -v bash >/dev/null 2>&1 || fail 'bash is required'

require_file "$repo_root" "$scratch" "$chezmoi_bin" private_dot_gnupg/.gpg-agent.linux.conf
require_file "$repo_root" "$scratch" "$chezmoi_bin" private_dot_gnupg/.gpg-agent.darwin.conf
require_file "$repo_root" "$scratch" "$chezmoi_bin" private_dot_gnupg/scdaemon.conf
require_file "$repo_root" "$scratch" "$chezmoi_bin" .chezmoiscripts/80-keys/run_onchange_after_reload-gpg-agent.sh.tmpl

# ---------------------------------------------------------------------------
# Scenario 1: gpg-agent.conf renders on linux (gnome, kde, none) and darwin
# ---------------------------------------------------------------------------
render_gpg_agent_conf() {
  local label=$1 os=$2 desktop=$3
  local out="$scratch/gpg-agent-$label.conf"
  env HOME="$scratch/home" PATH="$scratch/bin:/usr/bin:/bin" \
    "$chezmoi_bin" --config "$scratch/empty.toml" --source "$repo_root" --destination "$scratch/target" \
    --override-data "{\"chezmoi\":{\"os\":\"$os\"}}" \
    execute-template -f "$source_root/private_dot_gnupg/gpg-agent.conf.tmpl" > "$out"
  printf '%s\n' "$out"
}

expected_wrapper="$scratch/home/.gnupg/pinentry-card"

for variant in "gnome:linux:gnome" "kde:linux:kde" "none:linux:none" "darwin:darwin:gnome"; do
  IFS=':' read -r label os desktop <<< "$variant"
  conf=$(render_gpg_agent_conf "$label" "$os" "$desktop")

  grep -q "^pinentry-program $expected_wrapper$" "$conf" || \
    fail "$label: pinentry-program is not '$expected_wrapper' in rendered gpg-agent.conf ($(cat "$conf"))"

  if grep -v '^#' "$conf" | grep -E 'pinentry-(qt|gnome3|mac)' >/dev/null 2>&1; then
    fail "$label: direct pinentry-(qt|gnome3|mac) path remains active in gpg-agent.conf"
  fi
done
pass 'gpg-agent.conf points to wrapper under home dir with no direct pinentry paths on linux (gnome, kde, none) and darwin'

# ---------------------------------------------------------------------------
# Scenario 2: scdaemon.conf in scratch target tree
# ---------------------------------------------------------------------------
target_path=$("$chezmoi_bin" --source "$repo_root" target-path "$source_root/private_dot_gnupg/scdaemon.conf")
[[ "$target_path" == */.gnupg/scdaemon.conf ]] || \
  fail "target-path for scdaemon.conf ($target_path) does not end in .gnupg/scdaemon.conf"

mini_source="$scratch/mini-source/private_dot_gnupg"
mkdir -p "$mini_source"
cp "$source_root/private_dot_gnupg/scdaemon.conf" "$mini_source/scdaemon.conf"
tar_out="$scratch/scdaemon-archive.tar.gz"

env HOME="$scratch/home" PATH="$scratch/bin:/usr/bin:/bin" \
  "$chezmoi_bin" --config "$scratch/empty.toml" --source "$scratch/mini-source" --destination "$scratch/target" \
  archive -o "$tar_out"

tar -ztf "$tar_out" | grep -q '^\.gnupg/scdaemon\.conf$' || \
  fail 'archive target tree does not contain .gnupg/scdaemon.conf'

mkdir -p "$scratch/scdaemon-target"
tar -zxf "$tar_out" -C "$scratch/scdaemon-target" 2>/dev/null || tar -zxf "$tar_out" -C "$scratch/scdaemon-target"
scd_target="$scratch/scdaemon-target/.gnupg/scdaemon.conf"

grep -q '^disable-ccid$' "$scd_target" || fail 'scdaemon.conf missing disable-ccid'
grep -q '^pcsc-shared$' "$scd_target" || fail 'scdaemon.conf missing pcsc-shared'
grep -q 'KTD8' "$scd_target" || fail 'scdaemon.conf comment does not cite KTD8'
pass 'scratch target tree contains .gnupg/scdaemon.conf with disable-ccid and pcsc-shared citing KTD8'

# ---------------------------------------------------------------------------
# Scenario 3: reload script fails naming missing delegate before any gpgconf call
# ---------------------------------------------------------------------------
reload_script_tmpl="$source_root/.chezmoiscripts/80-keys/run_onchange_after_reload-gpg-agent.sh.tmpl"
rendered_reload_linux="$scratch/rendered-reload-linux.sh"
render "$repo_root" "$scratch" "$chezmoi_bin" linux "$reload_script_tmpl" "$rendered_reload_linux"

fake_missing_delegate="$scratch/nonexistent-pinentry-delegate"
rm -f "$fake_missing_delegate"

test_missing_delegate="$scratch/test-missing-delegate.sh"
sed "s|^DELEGATE_PATH=.*|DELEGATE_PATH=\"$fake_missing_delegate\"|" "$rendered_reload_linux" > "$test_missing_delegate"
chmod 755 "$test_missing_delegate"

mkdir -p "$scratch/spy-bin"
cat << EOF > "$scratch/spy-bin/gpgconf"
#!/usr/bin/env bash
printf 'CALLED: %s\n' "\$*" >> "$scratch/gpgconf-unexpected.log"
exit 99
EOF
chmod 755 "$scratch/spy-bin/gpgconf"

rm -f "$scratch/gpgconf-unexpected.log"
set +e
missing_out=$(env PATH="$scratch/spy-bin:/usr/bin:/bin" bash "$test_missing_delegate" 2>&1)
missing_status=$?
set -euo pipefail

[[ $missing_status -ne 0 ]] || fail 'reload script succeeded despite missing delegate path'
printf '%s\n' "$missing_out" | grep -F "$fake_missing_delegate" >/dev/null || \
  fail "reload script failure message did not name missing delegate: $missing_out"
[[ ! -f "$scratch/gpgconf-unexpected.log" ]] || \
  fail 'gpgconf was called before delegate existence check failed'
pass 'rendered reload script with missing delegate exits non-zero naming delegate before gpgconf call'

# ---------------------------------------------------------------------------
# Scenario 4: darwin variant fails naming xcode-select --install with failing xcode-select
# ---------------------------------------------------------------------------
rendered_reload_darwin="$scratch/rendered-reload-darwin.sh"
render "$repo_root" "$scratch" "$chezmoi_bin" darwin "$reload_script_tmpl" "$rendered_reload_darwin"

mkdir -p "$scratch/darwin-stub-bin"
cat << 'EOF' > "$scratch/darwin-stub-bin/xcode-select"
#!/usr/bin/env bash
exit 1
EOF
chmod 755 "$scratch/darwin-stub-bin/xcode-select"

test_darwin_reload="$scratch/test-darwin-reload.sh"
cp "$rendered_reload_darwin" "$test_darwin_reload"
chmod 755 "$test_darwin_reload"

rm -f "$scratch/gpgconf-unexpected.log"
set +e
darwin_out=$(env PATH="$scratch/darwin-stub-bin:$scratch/spy-bin:/usr/bin:/bin" bash "$test_darwin_reload" 2>&1)
darwin_status=$?
set -euo pipefail

[[ $darwin_status -ne 0 ]] || fail 'darwin reload script succeeded despite failing xcode-select'
printf '%s\n' "$darwin_out" | grep -F 'xcode-select --install' >/dev/null || \
  fail "darwin failure message did not name 'xcode-select --install': $darwin_out"
[[ ! -f "$scratch/gpgconf-unexpected.log" ]] || \
  fail 'gpgconf was called before xcode-select check failed'
pass 'darwin variant with failing xcode-select fails naming xcode-select --install before gpgconf call'

# ---------------------------------------------------------------------------
# Scenario 5: fingerprint lines, bash -n, and fake gpgconf logs reloads
# ---------------------------------------------------------------------------
for src_file in "$source_root/private_dot_gnupg"/* "$source_root/private_dot_gnupg"/.*; do
  [[ -f "$src_file" ]] || continue
  rel_path="private_dot_gnupg/${src_file##*/}"
  grep -qE "^#   $rel_path  [0-9a-f]{64}$" "$rendered_reload_linux" || \
    fail "rendered reload script missing fingerprint line for $rel_path"
done

bash -n "$rendered_reload_linux" || fail 'rendered linux reload script failed bash -n'
bash -n "$rendered_reload_darwin" || fail 'rendered darwin reload script failed bash -n'

mkdir -p "$scratch/fake-bin"
cat << EOF > "$scratch/fake-bin/gpgconf"
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$scratch/gpgconf.log"
EOF
chmod 755 "$scratch/fake-bin/gpgconf"
fake_delegate="$scratch/fake-bin/fake-delegate"
printf '#!/usr/bin/env bash\nexit 0\n' > "$fake_delegate"
chmod 755 "$fake_delegate"

test_reload_exec="$scratch/test-reload-exec.sh"
sed "s|^DELEGATE_PATH=.*|DELEGATE_PATH=\"$fake_delegate\"|" "$rendered_reload_linux" > "$test_reload_exec"
chmod 755 "$test_reload_exec"

rm -f "$scratch/gpgconf.log"
env PATH="$scratch/fake-bin:/usr/bin:/bin" bash "$test_reload_exec" || \
  fail 'rendered reload script failed under fake gpgconf'

[[ -f "$scratch/gpgconf.log" ]] || fail 'fake gpgconf was not called'
expected_calls=$'--reload gpg-agent\n--reload scdaemon'
actual_calls=$(cat "$scratch/gpgconf.log")
[[ "$actual_calls" == "$expected_calls" ]] || \
  fail "gpgconf calls ($actual_calls) did not match expected ($expected_calls)"
pass 'reload script lists fingerprint for every private_dot_gnupg file, passes bash -n, and logs gpgconf reloads'

# ---------------------------------------------------------------------------
# Scenario 6: real gpgconf with scratch GNUPGHOME and no agent exits 0
# ---------------------------------------------------------------------------
command -v gpgconf >/dev/null 2>&1 || fail 'real gpgconf required on PATH'
scratch_gnupghome="$scratch/gnupghome"
mkdir -p "$scratch_gnupghome"
chmod 700 "$scratch_gnupghome"

env GNUPGHOME="$scratch_gnupghome" PATH="/usr/bin:/bin" bash "$test_reload_exec" || \
  fail 'rendered reload script under real gpgconf with scratch GNUPGHOME failed'
pass 'rendered reload script under real gpgconf with scratch GNUPGHOME and no agent exits 0'

# ---------------------------------------------------------------------------
# Scenario 7: container variant of .chezmoiignore ignores reload-gpg-agent.sh
# ---------------------------------------------------------------------------
render_ignore "$repo_root" "$scratch" "$chezmoi_bin" linux true "$scratch/ignore-container.txt"
assert_gate "$repo_root" "$scratch" "$chezmoi_bin" "$scratch/ignore-container.txt" ignored \
  ".chezmoiscripts/80-keys/reload-gpg-agent.sh" "container ignore"

render_ignore "$repo_root" "$scratch" "$chezmoi_bin" linux false "$scratch/ignore-host.txt"
assert_gate "$repo_root" "$scratch" "$chezmoi_bin" "$scratch/ignore-host.txt" eligible \
  ".chezmoiscripts/80-keys/reload-gpg-agent.sh" "host ignore"
pass 'container variant of .chezmoiignore ignores .chezmoiscripts/80-keys/reload-gpg-agent.sh (eligible on host)'

# ---------------------------------------------------------------------------
# Scenario 8: darwin reload script selects the Homebrew prefix by arch (KTD6)
# ---------------------------------------------------------------------------
rendered_reload_darwin_arm64="$scratch/rendered-reload-darwin-arm64.sh"
render "$repo_root" "$scratch" "$chezmoi_bin" darwin "$reload_script_tmpl" "$rendered_reload_darwin_arm64" \
  '{"chezmoi":{"os":"darwin","arch":"arm64"}}'
grep -qF 'DELEGATE_PATH="/opt/homebrew/bin/pinentry-mac"' "$rendered_reload_darwin_arm64" || \
  fail 'darwin arm64 reload script does not name /opt/homebrew pinentry-mac'

rendered_reload_darwin_amd64="$scratch/rendered-reload-darwin-amd64.sh"
render "$repo_root" "$scratch" "$chezmoi_bin" darwin "$reload_script_tmpl" "$rendered_reload_darwin_amd64" \
  '{"chezmoi":{"os":"darwin","arch":"amd64"}}'
grep -qF 'DELEGATE_PATH="/usr/local/bin/pinentry-mac"' "$rendered_reload_darwin_amd64" || \
  fail 'darwin amd64 reload script does not name /usr/local pinentry-mac (Intel Homebrew prefix)'
pass 'darwin reload script selects /opt/homebrew on arm64 and /usr/local on amd64'

printf 'test-gnupg-config-render: all U6 test scenarios passed\n'
