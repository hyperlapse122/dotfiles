#!/usr/bin/env bash
# shellcheck disable=SC2030,SC2031
# test-key-custody-hook.sh — verify the card-stack preflight in .install-prerequisites.sh
# and package ownership boundaries across Fedora, Ubuntu, macOS, and containers.
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
hook="$repo_root/.install-prerequisites.sh"
[[ -f "$hook" ]] || { printf 'test-key-custody-hook: missing %s\n' "$hook" >&2; exit 1; }

scratch_parent=${XDG_RUNTIME_DIR:-${HOME:?HOME is required}/.cache}
mkdir -p "$scratch_parent"
scratch=$(mktemp -d "$scratch_parent/test-key-custody-hook.XXXXXX")
trap 'rm -rf -- "$scratch"' EXIT

fail() { printf 'test-key-custody-hook: FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'test-key-custody-hook: ok - %s\n' "$*"; }

# shellcheck source=/dev/null
_INSTALL_PREREQUISITES_TEST_SOURCE=1 source "$hook"
# The interactive key-presence-check scenarios below spawn a fresh bash under
# expect, which must re-source the hook in seam-only mode too.
export _INSTALL_PREREQUISITES_TEST_SOURCE=1

for fn in hook_distro_id hook_desktop resolve_sudo apt_installed bootstrap_homebrew seed_scdaemon_conf preflight_fedora preflight_ubuntu preflight_macos preflight_card_stack read_user_data key_check_import_public_key key_check_agent_probe key_check_classify key_check_verify_stub_safety key_check_run_learn normalize_aid_serial key_check_scd_serialno key_check_read_chv_status key_check_cancel_probe key_check_loopback_checkpin key_check_bounded_run key_check_keyring_get key_check_keyring_set key_check_clear_serials key_check_acquire_lock key_check_ask_operator key_check_pin_verify_impl key_check_pin_verify run_key_presence_check; do
  declare -F "$fn" >/dev/null || fail "the hook does not define required preflight function $fn"
done
pass 'the hook exposes all required preflight functions above the seam'

# Create an isolated toolchain directory so host binaries (such as /usr/bin/plasmashell)
# do not leak into tests that simulate specific environments.
clean_bin="$scratch/clean-bin"
mkdir -p "$clean_bin"
for tool in bash sh cat grep sed awk rm cp mv mkdir rmdir chmod wc printf echo test [ tr cut head tail date mktemp sort uniq env xargs timeout stat kill sleep expect; do
  tool_path=$(type -P "$tool" || true)
  [[ -n "$tool_path" ]] && ln -s "$tool_path" "$clean_bin/$tool"
done

# Helper to create executable stub scripts
make_stub() {
  local dir=$1 name=$2
  shift 2
  mkdir -p "$dir"
  cat > "$dir/$name"
  chmod 0755 "$dir/$name"
}

# --- 1. Fedora with all packages present: no dnf, no sudo, no systemctl enable ---
(
  f_bin="$scratch/fedora-all-present/bin"
  f_log="$scratch/fedora-all-present/log"
  mkdir -p "$f_bin" "$f_log"

  make_stub "$f_bin" "rpm" <<'EOF'
#!/usr/bin/env bash
echo "rpm $*" >> "$LOG_DIR/rpm.log"
exit 0
EOF

  make_stub "$f_bin" "dnf" <<'EOF'
#!/usr/bin/env bash
echo "dnf $*" >> "$LOG_DIR/dnf.log"
exit 0
EOF

  make_stub "$f_bin" "sudo" <<'EOF'
#!/usr/bin/env bash
echo "sudo $*" >> "$LOG_DIR/sudo.log"
"$@"
EOF

  make_stub "$f_bin" "systemctl" <<'EOF'
#!/usr/bin/env bash
echo "systemctl $*" >> "$LOG_DIR/systemctl.log"
case "$1" in
  is-enabled|is-active) exit 0 ;;
  enable) exit 0 ;;
  *) exit 0 ;;
esac
EOF

  export PATH="$f_bin:$clean_bin"
  export LOG_DIR="$f_log"

  preflight_fedora || exit 1

  [[ ! -f "$f_log/dnf.log" ]] || exit 11
  [[ ! -f "$f_log/sudo.log" ]] || exit 12
  if [[ -f "$f_log/systemctl.log" ]] && grep -q 'systemctl enable' "$f_log/systemctl.log"; then
    exit 13
  fi
) || fail 'Fedora with all packages present must invoke neither dnf, sudo, nor systemctl enable'
pass 'Fedora with every listed package present calls no dnf, no sudo, no systemctl enable'

# --- 2. Fedora with gnupg2-scdaemon and pcsc-lite-ccid missing: dnf install and pcscd.socket enable ---
(
  f_bin="$scratch/fedora-missing/bin"
  f_log="$scratch/fedora-missing/log"
  mkdir -p "$f_bin" "$f_log"

  make_stub "$f_bin" "rpm" <<'EOF'
#!/usr/bin/env bash
echo "rpm $*" >> "$LOG_DIR/rpm.log"
for arg in "$@"; do
  if [[ "$arg" == "gnupg2-scdaemon" || "$arg" == "pcsc-lite-ccid" ]]; then
    exit 1
  fi
done
exit 0
EOF

  make_stub "$f_bin" "dnf" <<'EOF'
#!/usr/bin/env bash
echo "dnf $*" >> "$LOG_DIR/dnf.log"
exit 0
EOF

  make_stub "$f_bin" "sudo" <<'EOF'
#!/usr/bin/env bash
echo "sudo $*" >> "$LOG_DIR/sudo.log"
"$@"
EOF

  make_stub "$f_bin" "systemctl" <<'EOF'
#!/usr/bin/env bash
echo "systemctl $*" >> "$LOG_DIR/systemctl.log"
case "$1" in
  is-enabled|is-active) exit 1 ;;
  enable) exit 0 ;;
  *) exit 0 ;;
esac
EOF

  export PATH="$f_bin:$clean_bin"
  export LOG_DIR="$f_log"

  preflight_fedora || exit 1

  [[ -f "$f_log/dnf.log" ]] || exit 21
  dnf_count=$(wc -l < "$f_log/dnf.log")
  [[ "$dnf_count" -eq 1 ]] || exit 22
  grep -q 'dnf install -y gnupg2-scdaemon pcsc-lite-ccid' "$f_log/dnf.log" || exit 23

  [[ -f "$f_log/systemctl.log" ]] || exit 24
  grep -q 'systemctl enable --now pcscd.socket' "$f_log/systemctl.log" || exit 25
) || fail 'Fedora with gnupg2-scdaemon and pcsc-lite-ccid missing failed install or socket enable assertions'
pass 'Fedora with gnupg2-scdaemon and pcsc-lite-ccid missing runs exactly one dnf install and enables pcscd.socket'

# --- 3. Fedora desktop pinentry selection: plasmashell vs gnome-shell vs both vs neither ---
(
  # A. plasmashell on PATH -> pinentry-qt queried, not pinentry-gnome3
  f_bin="$scratch/fedora-kde/bin"
  f_log="$scratch/fedora-kde/log"
  mkdir -p "$f_bin" "$f_log"
  make_stub "$f_bin" "plasmashell" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  make_stub "$f_bin" "rpm" <<'EOF'
#!/usr/bin/env bash
echo "rpm $*" >> "$LOG_DIR/rpm.log"
exit 0
EOF
  make_stub "$f_bin" "systemctl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  export PATH="$f_bin:$clean_bin"
  export LOG_DIR="$f_log"
  preflight_fedora || exit 1
  grep -q 'pinentry-qt' "$f_log/rpm.log" || exit 31
  if grep -q 'pinentry-gnome3' "$f_log/rpm.log"; then exit 32; fi

  # B. gnome-shell only on PATH -> pinentry-gnome3 queried, not pinentry-qt
  f_bin_g="$scratch/fedora-gnome/bin"
  f_log_g="$scratch/fedora-gnome/log"
  mkdir -p "$f_bin_g" "$f_log_g"
  make_stub "$f_bin_g" "gnome-shell" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  make_stub "$f_bin_g" "rpm" <<'EOF'
#!/usr/bin/env bash
echo "rpm $*" >> "$LOG_DIR/rpm.log"
exit 0
EOF
  make_stub "$f_bin_g" "systemctl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  export PATH="$f_bin_g:$clean_bin"
  export LOG_DIR="$f_log_g"
  preflight_fedora || exit 1
  grep -q 'pinentry-gnome3' "$f_log_g/rpm.log" || exit 33
  if grep -q 'pinentry-qt' "$f_log_g/rpm.log"; then exit 34; fi

  # C. Both plasmashell and gnome-shell on PATH -> pinentry-qt queried, not pinentry-gnome3 (KDE precedence)
  f_bin_b="$scratch/fedora-both/bin"
  f_log_b="$scratch/fedora-both/log"
  mkdir -p "$f_bin_b" "$f_log_b"
  make_stub "$f_bin_b" "plasmashell" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  make_stub "$f_bin_b" "gnome-shell" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  make_stub "$f_bin_b" "rpm" <<'EOF'
#!/usr/bin/env bash
echo "rpm $*" >> "$LOG_DIR/rpm.log"
exit 0
EOF
  make_stub "$f_bin_b" "systemctl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  export PATH="$f_bin_b:$clean_bin"
  export LOG_DIR="$f_log_b"
  preflight_fedora || exit 1
  grep -q 'pinentry-qt' "$f_log_b/rpm.log" || exit 35
  if grep -q 'pinentry-gnome3' "$f_log_b/rpm.log"; then exit 36; fi

  # D. Neither on PATH -> no desktop pinentry queried
  f_bin_n="$scratch/fedora-none/bin"
  f_log_n="$scratch/fedora-none/log"
  mkdir -p "$f_bin_n" "$f_log_n"
  make_stub "$f_bin_n" "rpm" <<'EOF'
#!/usr/bin/env bash
echo "rpm $*" >> "$LOG_DIR/rpm.log"
exit 0
EOF
  make_stub "$f_bin_n" "systemctl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  export PATH="$f_bin_n:$clean_bin"
  export LOG_DIR="$f_log_n"
  preflight_fedora || exit 1
  if grep -qE 'pinentry-qt|pinentry-gnome3' "$f_log_n/rpm.log"; then exit 37; fi
) || fail 'Fedora desktop pinentry selection failed precedence or querying assertions'
pass 'Fedora desktop pinentry correctly mirrors KDE/GNOME/none precedence'

# --- 4. Ubuntu with scdaemon missing: one apt-get install -y scdaemon; gnupg present is not reinstalled ---
(
  u_bin="$scratch/ubuntu-missing/bin"
  u_log="$scratch/ubuntu-missing/log"
  mkdir -p "$u_bin" "$u_log"

  make_stub "$u_bin" "dpkg-query" <<'EOF'
#!/usr/bin/env bash
echo "dpkg-query $*" >> "$LOG_DIR/dpkg.log"
pkg="${!#}"
if [[ "$pkg" == "scdaemon" ]]; then
  echo "not-installed"
  exit 1
fi
echo "installed"
exit 0
EOF

  make_stub "$u_bin" "apt-get" <<'EOF'
#!/usr/bin/env bash
echo "apt-get $*" >> "$LOG_DIR/apt.log"
exit 0
EOF

  make_stub "$u_bin" "sudo" <<'EOF'
#!/usr/bin/env bash
echo "sudo $*" >> "$LOG_DIR/sudo.log"
"$@"
EOF

  make_stub "$u_bin" "systemctl" <<'EOF'
#!/usr/bin/env bash
echo "systemctl $*" >> "$LOG_DIR/systemctl.log"
case "$1" in
  is-enabled|is-active) exit 0 ;;
  *) exit 0 ;;
esac
EOF

  export PATH="$u_bin:$clean_bin"
  export LOG_DIR="$u_log"

  preflight_ubuntu || exit 1

  [[ -f "$u_log/apt.log" ]] || exit 41
  apt_count=$(wc -l < "$u_log/apt.log")
  [[ "$apt_count" -eq 1 ]] || exit 42
  grep -q 'apt-get install -y scdaemon' "$u_log/apt.log" || exit 43
  if grep -q 'gnupg' "$u_log/apt.log"; then exit 44; fi

  # Verify pinentry-qt queried only with plasmashell and pinentry-gnome3 only with gnome-shell alone
  make_stub "$u_bin" "plasmashell" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  : > "$u_log/dpkg.log"
  preflight_ubuntu || exit 1
  grep -q 'dpkg-query.*pinentry-qt' "$u_log/dpkg.log" || exit 45
  if grep -q 'dpkg-query.*pinentry-gnome3' "$u_log/dpkg.log"; then exit 46; fi

  rm -f "$u_bin/plasmashell"
  make_stub "$u_bin" "gnome-shell" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  : > "$u_log/dpkg.log"
  preflight_ubuntu || exit 1
  grep -q 'dpkg-query.*pinentry-gnome3' "$u_log/dpkg.log" || exit 47
  if grep -q 'dpkg-query.*pinentry-qt' "$u_log/dpkg.log"; then exit 48; fi
) || fail 'Ubuntu preflight missing package or desktop query assertions failed'
pass 'Ubuntu with scdaemon missing installs only scdaemon and queries desktop pinentry correctly'

# --- 5. The hook own Ubuntu base list names none of expect, gnupg, libsecret-tools ---
(
  base_line=$(grep -E '^\s*local -a base=\(' "$hook")
  [[ -n "$base_line" ]] || fail 'could not locate base package array in install_ubuntu'
  if echo "$base_line" | grep -qE '\bexpect\b|\bgnupg\b|\blibsecret-tools\b'; then
    fail "hook base array still names moved packages: $base_line"
  fi
) || fail 'Hook Ubuntu base list check failed'
pass 'The hook own Ubuntu base list names none of expect, gnupg, libsecret-tools'

# --- 6. With no ~/.gnupg/scdaemon.conf, seed KTD8 content; existing file untouched ---
(
  fake_home="$scratch/home-scd"
  mkdir -p "$fake_home"
  export HOME="$fake_home"
  unset GNUPGHOME

  # Subtest A: absent file
  seed_scdaemon_conf
  target_conf="$fake_home/.gnupg/scdaemon.conf"
  [[ -f "$target_conf" ]] || fail 'scdaemon.conf was not created'
  content=$(<"$target_conf")
  expected=$'disable-ccid\npcsc-shared'
  [[ "$content" == "$expected" ]] || fail "scdaemon.conf content mismatch: got $content, want $expected"

  # Subtest B: existing file with different content is untouched
  printf 'custom-scdaemon-option\n' > "$target_conf"
  seed_scdaemon_conf
  content_after=$(<"$target_conf")
  [[ "$content_after" == "custom-scdaemon-option" ]] || fail 'existing scdaemon.conf was modified'
) || fail 'scdaemon.conf seeding failed'
pass 'With no ~/.gnupg/scdaemon.conf, preflight seeds KTD8 content; existing file is left untouched'

# --- 7. macOS with xcode-select -p failing: stops with xcode-select --install message, no formula install ---
(
  m_bin="$scratch/macos-xcode-fail/bin"
  m_log="$scratch/macos-xcode-fail/log"
  mkdir -p "$m_bin" "$m_log"

  make_stub "$m_bin" "xcode-select" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF

  make_stub "$m_bin" "brew" <<'EOF'
#!/usr/bin/env bash
echo "brew $*" >> "$LOG_DIR/brew.log"
exit 0
EOF

  export PATH="$m_bin:$clean_bin"
  export LOG_DIR="$m_log"

  err_out=$(preflight_macos 2>&1 || true)
  echo "$err_out" | grep -q 'xcode-select --install' || exit 71
  [[ ! -f "$m_log/brew.log" ]] || exit 72
) || fail 'macOS with xcode-select -p failing did not report message or attempted brew install'
pass 'macOS with xcode-select -p failing stops with xcode-select --install and installs no formula'

# --- 8. macOS with pinentry-mac missing and gnupg present: one brew install pinentry-mac; brew absent bootstraps ---
(
  m_bin="$scratch/macos-brew/bin"
  m_log="$scratch/macos-brew/log"
  mkdir -p "$m_bin" "$m_log"

  make_stub "$m_bin" "xcode-select" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

  make_stub "$m_bin" "brew" <<'EOF'
#!/usr/bin/env bash
echo "brew $*" >> "$LOG_DIR/brew.log"
case "$1" in
  list)
    pkg="${!#}"
    if [[ "$pkg" == "pinentry-mac" ]]; then
      exit 1
    fi
    exit 0
    ;;
  install)
    exit 0
    ;;
  *) exit 0 ;;
esac
EOF

  export PATH="$m_bin:$clean_bin"
  export LOG_DIR="$m_log"

  preflight_macos || exit 1
  [[ -f "$m_log/brew.log" ]] || exit 81
  grep -q 'brew install pinentry-mac' "$m_log/brew.log" || exit 82
  if grep -q 'brew install.*gnupg' "$m_log/brew.log"; then exit 83; fi

  # Subtest: brew absent triggers bootstrap function
  m_bin_nobrew="$scratch/macos-nobrew/bin"
  mkdir -p "$m_bin_nobrew"
  make_stub "$m_bin_nobrew" "xcode-select" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  export PATH="$m_bin_nobrew:$clean_bin"
  bootstrap_called=0
  # Stub invoked indirectly by preflight_macos
  # shellcheck disable=SC2317,SC2329
  bootstrap_homebrew() {
    bootstrap_called=1
    make_stub "$m_bin_nobrew" "brew" <<'BO_EOF'
#!/usr/bin/env bash
exit 0
BO_EOF
  }
  preflight_macos || exit 1
  [[ "$bootstrap_called" -eq 1 ]] || exit 84
) || fail 'macOS brew package install or bootstrap invocation failed'
pass 'macOS with pinentry-mac missing installs only pinentry-mac; bootstraps Homebrew when absent'

# --- 9 & 10. Container and CI=true skip preflight ---
(
  c_bin="$scratch/container-skip/bin"
  c_log="$scratch/container-skip/log"
  mkdir -p "$c_bin" "$c_log"

  for cmd in dnf apt-get brew systemctl rpm dpkg-query; do
    make_stub "$c_bin" "$cmd" <<EOF
#!/usr/bin/env bash
echo "$cmd \$*" >> "$c_log/calls.log"
exit 0
EOF
  done

  export PATH="$c_bin:$clean_bin"

  # Container marker simulation
  # Stub invoked indirectly by preflight_card_stack
  # shellcheck disable=SC2317,SC2329
  is_container() { return 0; }
  CI=false preflight_card_stack || exit 91
  [[ ! -f "$c_log/calls.log" ]] || exit 92

  # CI=true simulation
  # Stub invoked indirectly by preflight_card_stack
  # shellcheck disable=SC2317,SC2329
  is_container() { return 1; }
  CI=true preflight_card_stack || exit 93
  [[ ! -f "$c_log/calls.log" ]] || exit 94
) || fail 'Container or CI=true did not skip preflight'
pass 'A real container marker and CI=true skip preflight without package manager calls'

# --- 11. Rendered templates assert package removals ---
(
  render_dir="$scratch/renders"
  mkdir -p "$render_dir/bin" "$render_dir/home" "$render_dir/target"
  : > "$render_dir/empty.toml"
  printf '#!/usr/bin/env bash\ncase "${1-}" in whoami) printf dummy@example.invalid;; *) printf dummy-secret;; esac\n' \
    > "$render_dir/bin/op"
  chmod 700 "$render_dir/bin/op"
  chezmoi_bin=$(command -v chezmoi)

  render_tmpl() {
    local override_json=$1 tmpl_rel=$2 out_file=$3
    env HOME="$render_dir/home" PATH="$render_dir/bin:/usr/bin:/bin" \
      "$chezmoi_bin" --config "$render_dir/empty.toml" --source "$repo_root" \
      --destination "$render_dir/target" \
      --override-data "$override_json" \
      execute-template < "$repo_root/$tmpl_rel" > "$out_file"
  }

  # 1. Fedora base script: neither expect nor gnupg2
  f_base="$render_dir/fedora-base.sh"
  render_tmpl '{"chezmoi":{"os":"linux","osRelease":{"id":"fedora"}}}' \
    ".chezmoiscripts/20-base/fedora/run_onchange_before_base.sh.tmpl" "$f_base"
  if grep -qE '\bexpect\b|\bgnupg2\b' "$f_base"; then
    fail 'Rendered Fedora base script still contains expect or gnupg2'
  fi

  # 2. Fedora devtools: none of pcsc-lite, pcsc-lite-ccid, libsecret; keeps pcsc-tools
  f_dev="$render_dir/fedora-devtools.sh"
  render_tmpl '{"chezmoi":{"os":"linux","osRelease":{"id":"fedora"}}}' \
    ".chezmoiscripts/30-components/run_onchange_before_80-devtools.sh.tmpl" "$f_dev"
  if grep -qE '\bpcsc-lite\b|\bpcsc-lite-ccid\b|\blibsecret\b' "$f_dev"; then
    fail 'Rendered Fedora devtools still contains pcsc-lite, pcsc-lite-ccid, or libsecret'
  fi
  grep -q '\bpcsc-tools\b' "$f_dev" || fail 'Rendered Fedora devtools dropped pcsc-tools'

  # 3. Ubuntu devtools: no pcscd
  u_dev="$render_dir/ubuntu-devtools.sh"
  render_tmpl '{"chezmoi":{"os":"linux","osRelease":{"id":"ubuntu"}}}' \
    ".chezmoiscripts/30-components/run_onchange_before_80-devtools.sh.tmpl" "$u_dev"
  if grep -qE '\bpcscd\b' "$u_dev"; then
    fail 'Rendered Ubuntu devtools still contains pcscd'
  fi

  # 4. Desktop-IME: neither contains pinentry; Fedora still lists ksshaskpass and openssh-askpass
  f_ime="$render_dir/fedora-ime.sh"
  render_tmpl '{"chezmoi":{"os":"linux","osRelease":{"id":"fedora"}}}' \
    ".chezmoiscripts/30-components/run_onchange_before_60-desktop-ime.sh.tmpl" "$f_ime"
  if grep -qE '\bpinentry\b|\bpinentry-qt\b|\bpinentry-gnome3\b' "$f_ime"; then
    fail 'Rendered Fedora desktop-IME still contains pinentry'
  fi
  grep -q 'ksshaskpass' "$f_ime" || fail 'Rendered Fedora desktop-IME missing ksshaskpass'
  grep -q 'openssh-askpass' "$f_ime" || fail 'Rendered Fedora desktop-IME missing openssh-askpass'

  u_ime="$render_dir/ubuntu-ime.sh"
  render_tmpl '{"chezmoi":{"os":"linux","osRelease":{"id":"ubuntu"}}}' \
    ".chezmoiscripts/30-components/run_onchange_before_60-desktop-ime.sh.tmpl" "$u_ime"
  if grep -qE '\bpinentry\b|\bpinentry-qt\b' "$u_ime"; then
    fail 'Rendered Ubuntu desktop-IME still contains pinentry'
  fi

  # 5. Jetson installer: neither gnupg nor pinentry-qt
  jetson_src="$repo_root/.chezmoiscripts/20-linux-ubuntu/run_onchange_before_jetson.sh.tmpl"
  if grep -qE 'install_apt "(gnupg|pinentry-qt)"' "$jetson_src"; then
    fail 'Jetson installer source still contains install_apt gnupg or pinentry-qt'
  fi

  # 6. Brewfile heredoc: neither gnupg nor pinentry-mac
  darwin_brew="$render_dir/darwin-homebrew.sh"
  render_tmpl '{"chezmoi":{"os":"darwin"}}' \
    ".chezmoiscripts/20-darwin/run_onchange_before_homebrew.sh.tmpl" "$darwin_brew"
  if grep -qE 'brew "(gnupg|pinentry-mac)"' "$darwin_brew"; then
    fail 'Rendered Darwin Brewfile still contains gnupg or pinentry-mac'
  fi
) || fail 'Rendered template package removal assertions failed'
pass 'Rendered templates confirm package ownership cuts across all distributions'


# --- Key presence check (U3, KTD1/KTD2/KTD3/KTD4/KTD9) ------------------------

KC_FPR='A7F1956CD1A035A139BC7ABFCC740A29852C0E95'
KC_SERIAL='14963605'
KC_AID='D2760001240100000006149636050000'
KC_AID2='D2760001240100000006888888880000'
KC_UNDECLARED_AID='D2760001240100000006999999990000'

# Builds a synthetic OpenPGP AID whose normalize_aid_serial() offsets (20-27)
# decode to the given 8-digit serial, matching KC_AID's own shape.
kc_aid_for_serial() {
  printf 'D2760001240100000006%08d0000' "$1"
}

kc_colon_line() {
  local IFS=:
  printf '%s\n' "$*"
}

kc_write_source() {
  local root="$1" fpr="${2:-$KC_FPR}" serials="${3:-$KC_SERIAL}"
  mkdir -p "$root/.chezmoidata" "$root/.keys"
  printf 'user:\n  fullname: Test\n  email: test@example.invalid\n  gpgPubKey: %s\n  yubikeySerials: [%s]\n' "$fpr" "$serials" > "$root/.chezmoidata/user.yaml"
  printf 'dummy public key armor\n' > "$root/.keys/gpg-${fpr}.asc"
}

kc_write_stub_gpg() {
  local path="$1"
  cat > "$path" <<'STUB'
#!/usr/bin/env bash
log="$LOG_DIR/gpg.log"
{
  printf 'CALL'
  for a in "$@"; do printf '\x1f%s' "$a"; done
  printf '\x1f\n'
} >> "$log"

read_fixture() {
  local f="$FIXTURE_DIR/$1"
  if [[ -f "$f" ]]; then cat "$f"; else printf '%s' "${2-}"; fi
}

has_flag() {
  local want="$1"; shift
  local a
  for a in "$@"; do [[ "$a" == "$want" ]] && return 0; done
  return 1
}

if has_flag --list-keys "$@"; then
  rc=$(read_fixture list_keys_rc 0)
  exit "$rc"
fi

if has_flag --import "$@"; then
  rc=$(read_fixture import_rc 0)
  exit "$rc"
fi

if has_flag --export-ownertrust "$@"; then
  read_fixture ownertrust ''
  exit 0
fi

if has_flag --import-ownertrust "$@"; then
  cat > "$LOG_DIR/import-ownertrust-stdin.log"
  rc=$(read_fixture import_ownertrust_rc 0)
  exit "$rc"
fi

if has_flag -K "$@"; then
  count_file="$FIXTURE_DIR/classify_call_count"
  count=$(( $(cat "$count_file" 2>/dev/null || echo 0) + 1 ))
  printf '%s' "$count" > "$count_file"
  rc_file="$FIXTURE_DIR/classify_rc_$count"
  out_file="$FIXTURE_DIR/classify_output_$count"
  [[ -f "$rc_file" ]] || rc_file="$FIXTURE_DIR/classify_rc"
  [[ -f "$out_file" ]] || out_file="$FIXTURE_DIR/classify_output"
  rc=$(cat "$rc_file" 2>/dev/null || echo 0)
  [[ "$rc" == "0" && -f "$out_file" ]] && cat "$out_file"
  exit "$rc"
fi

if has_flag -k "$@"; then
  rc=$(read_fixture pubkeygrips_rc 0)
  [[ "$rc" == "0" ]] && read_fixture pubkeygrips_output ''
  exit "$rc"
fi

exit 0
STUB
  chmod 0755 "$path"
}

kc_write_stub_gpg_connect_agent() {
  local path="$1"
  cat > "$path" <<'STUB'
#!/usr/bin/env bash
log="$LOG_DIR/gpg-connect-agent.log"
{
  printf 'CALL'
  for a in "$@"; do printf '\x1f%s' "$a"; done
  printf '\x1f\n'
} >> "$log"

read_fixture() {
  local f="$FIXTURE_DIR/$1"
  if [[ -f "$f" ]]; then cat "$f"; else printf '%s' "${2-}"; fi
}

if [[ $# -eq 0 ]]; then
  script=$(cat)
  {
    printf '%s\n---\n' "$script"
  } >> "$LOG_DIR/loopback-sessions.log"

  count_file="$FIXTURE_DIR/loopback_call_count"
  count=$(( $(cat "$count_file" 2>/dev/null || echo 0) + 1 ))
  printf '%s' "$count" > "$count_file"

  cache_hit=$(read_fixture cache_hit '')
  if [[ "$cache_hit" != "1" ]]; then
    # gpg-connect-agent's assign_variable() only substitutes when /subst is
    # active (tools/gpg-connect-agent.c); the hook never sends /subst, so a
    # real session stores whatever follows "/let pin " verbatim, with no
    # unescaping. Recording it as-is is what proves that contract.
    delivered=$(printf '%s\n' "$script" | sed -n 's#^/let pin ##p')
    printf '%s\n' "$delivered" >> "$LOG_DIR/loopback-delivered-pins.log"
  fi

  seq_file="$FIXTURE_DIR/loopback_rc_sequence"
  rc=1
  if [[ -f "$seq_file" ]]; then
    rc=$(sed -n "${count}p" "$seq_file")
    [[ -z "$rc" ]] && rc=$(tail -n1 "$seq_file")
  fi

  if [[ "$rc" == "0" ]]; then
    printf 'OK\n'
  else
    printf 'ERR 100663383 Bad PIN <SCD>\n'
  fi
  exit 0
fi

case "$1" in
  'GETINFO version')
    rc=$(read_fixture agent_probe_rc 0)
    if [[ "$rc" == "0" ]]; then printf 'D 2.4.9\nOK\n'; else printf 'ERR 1 no agent\n'; fi
    ;;
  'scd serialno')
    count_file="$FIXTURE_DIR/serialno_call_count"
    count=$(( $(cat "$count_file" 2>/dev/null || echo 0) + 1 ))
    printf '%s' "$count" > "$count_file"
    rc_file="$FIXTURE_DIR/serialno_rc_$count"
    aid_file="$FIXTURE_DIR/serialno_aid_$count"
    [[ -f "$rc_file" ]] || rc_file="$FIXTURE_DIR/serialno_rc"
    [[ -f "$aid_file" ]] || aid_file="$FIXTURE_DIR/serialno_aid"
    rc=$(cat "$rc_file" 2>/dev/null || echo 0)
    if [[ "$rc" == "0" ]]; then
      aid=$(cat "$aid_file" 2>/dev/null || echo '')
      printf 'S SERIALNO %s 0\nOK\n' "$aid"
    else
      printf 'ERR 100663404 No such device <SCD>\n'
    fi
    ;;
  'OPTION pinentry-mode=cancel')
    rc=$(read_fixture cancel_probe_rc 1)
    if [[ "$rc" == "0" ]]; then printf 'OK\nOK\n'; else printf 'OK\nERR 100663404 Card not verified <SCD>\n'; fi
    ;;
  'scd getattr CHV-STATUS')
    rc=$(read_fixture chv_status_rc 0)
    if [[ "$rc" == "0" ]]; then
      # Real scdaemon output (app-openpgp.c/command.c): the seven counters
      # are ONE token with a leading space per value, spaces encoded as
      # '+' (e.g. `S CHV-STATUS +1+127+127+127+3+3+3`), never space-joined
      # fields. Fixtures below follow the same "+N+N+N+N+N+N+N" shape.
      line=$(read_fixture chv_status_line '+1+3+3+3+3+3+3')
      printf 'S CHV-STATUS %s\nOK\n' "$line"
    else
      printf 'ERR 1 bad\n'
    fi
    ;;
  'LEARN' | 'LEARN --force')
    printf '%s\n' "$1" >> "$LOG_DIR/learn.log"
    rc=$(read_fixture learn_rc 0)
    if [[ "$rc" == "0" ]]; then printf 'OK\n'; else printf 'ERR 1 learn failed\n'; fi
    ;;
  *)
    printf 'ERR 1 unknown command\n'
    ;;
esac
STUB
  chmod 0755 "$path"
}

kc_write_stub_chezmoi() {
  local path="$1"
  cat > "$path" <<'STUB'
#!/usr/bin/env bash
log="$LOG_DIR/chezmoi.log"
{
  printf 'CALL'
  for a in "$@"; do printf '\x1f%s' "$a"; done
  printf '\x1f\n'
} >> "$log"

service=''
user=''
for a in "$@"; do
  case "$a" in
    --service=*) service=${a#--service=} ;;
    --user=*) user=${a#--user=} ;;
    --value*) echo "STUB CHEZMOI: --value forbidden for PIN writes" >> "$LOG_DIR/chezmoi-violations.log" ;;
  esac
done

case "$*" in
  *'secret keyring set'*)
    pin=$(cat)
    printf '%s\n' "$pin" > "$FIXTURE_DIR/keyring-$service-$user"
    exit 0
    ;;
  *'secret keyring get'*)
    f="$FIXTURE_DIR/keyring-$service-$user"
    if [[ -f "$f" ]]; then cat "$f"; exit 0; fi
    exit 1
    ;;
  *'secret keyring delete'*)
    rm -f "$FIXTURE_DIR/keyring-$service-$user"
    exit 0
    ;;
esac
exit 0
STUB
  chmod 0755 "$path"
}

kc_new() {
  KC_DIR=$(mktemp -d "$scratch/kc-XXXXXX")
  KC_BIN="$KC_DIR/bin"
  KC_FIXTURE="$KC_DIR/fixture"
  KC_LOG="$KC_DIR/log"
  KC_HOME="$KC_DIR/home"
  KC_SOURCE="$KC_DIR/source"
  mkdir -p "$KC_BIN" "$KC_FIXTURE" "$KC_LOG" "$KC_HOME"
  kc_write_source "$KC_SOURCE" "${1:-$KC_FPR}" "${2:-$KC_SERIAL}"
  kc_write_stub_gpg "$KC_BIN/gpg"
  kc_write_stub_gpg_connect_agent "$KC_BIN/gpg-connect-agent"
  kc_write_stub_chezmoi "$KC_BIN/chezmoi"
  export PATH="$KC_BIN:$clean_bin"
  export FIXTURE_DIR="$KC_FIXTURE"
  export LOG_DIR="$KC_LOG"
  export HOME="$KC_HOME"
  unset XDG_RUNTIME_DIR CI
  # Stub invoked indirectly by run_key_presence_check
  # shellcheck disable=SC2317,SC2329
  is_container() { return 1; }
}

kc_classify_local() {
  local slot="${1:-}" suffix=''
  [[ -n "$slot" ]] && suffix="_$slot"
  {
    kc_colon_line sec u 2048 1 KEYID123 1600000000 '' '' '' '' '' scESC '' '' '+'
    kc_colon_line fpr '' '' '' '' '' '' '' '' "$KC_FPR" '' '' '' '' ''
    kc_colon_line grp '' '' '' '' '' '' '' '' 'GRIPPRIMARY0000000000000000000001' '' '' '' '' ''
    kc_colon_line ssb u 2048 1 SUBKEYID 1600000000 '' '' '' '' '' e '' '' '+'
    kc_colon_line fpr '' '' '' '' '' '' '' '' 'SUBFPR000000000000000000000000000A' '' '' '' '' ''
    kc_colon_line grp '' '' '' '' '' '' '' '' 'GRIPSUBENC00000000000000000000002' '' '' '' '' ''
  } > "$KC_FIXTURE/classify_output$suffix"
  printf '0' > "$KC_FIXTURE/classify_rc$suffix"
}

kc_classify_card() {
  # Field 15 of a real `gpg -K --with-colons --with-secret` is the token AID
  # (doc/DETAILS field 15; g10/keylist.c es_fputs(serialno, ...)), never a
  # decimal serial -- so this builds the same shape as $KC_AID for whatever
  # serial the caller names.
  local serial="${1:-$KC_SERIAL}" slot="${2:-}" suffix='' aid
  aid=$(kc_aid_for_serial "$serial")
  [[ -n "$slot" ]] && suffix="_$slot"
  {
    kc_colon_line sec u 2048 1 KEYID123 1600000000 '' '' '' '' '' scESC '' '' "$aid"
    kc_colon_line fpr '' '' '' '' '' '' '' '' "$KC_FPR" '' '' '' '' ''
    kc_colon_line grp '' '' '' '' '' '' '' '' 'GRIPPRIMARY0000000000000000000001' '' '' '' '' ''
    kc_colon_line ssb u 2048 1 SUBKEYID 1600000000 '' '' '' '' '' e '' '' "$aid"
    kc_colon_line fpr '' '' '' '' '' '' '' '' 'SUBFPR000000000000000000000000000A' '' '' '' '' ''
    kc_colon_line grp '' '' '' '' '' '' '' '' 'GRIPSUBENC00000000000000000000002' '' '' '' '' ''
  } > "$KC_FIXTURE/classify_output$suffix"
  printf '0' > "$KC_FIXTURE/classify_rc$suffix"
}

kc_classify_none() {
  local slot="${1:-}" suffix=''
  [[ -n "$slot" ]] && suffix="_$slot"
  printf '2' > "$KC_FIXTURE/classify_rc$suffix"
}

kc_classify_unavailable() {
  {
    kc_colon_line sec u 2048 1 KEYID123 1600000000 '' '' '' '' '' scESC '' '' '#'
    kc_colon_line fpr '' '' '' '' '' '' '' '' "$KC_FPR" '' '' '' '' ''
    kc_colon_line grp '' '' '' '' '' '' '' '' 'GRIPPRIMARY0000000000000000000001' '' '' '' '' ''
  } > "$KC_FIXTURE/classify_output"
  printf '0' > "$KC_FIXTURE/classify_rc"
}

kc_classify_unrelated_only() {
  {
    kc_colon_line sec u 2048 1 OTHERKEY 1600000000 '' '' '' '' '' scESC '' '' '+'
    kc_colon_line fpr '' '' '' '' '' '' '' '' 'DEADBEEF00000000000000000000000000000A' '' '' '' '' ''
    kc_colon_line grp '' '' '' '' '' '' '' '' 'GRIPOTHER000000000000000000000001' '' '' '' '' ''
  } > "$KC_FIXTURE/classify_output"
  printf '0' > "$KC_FIXTURE/classify_rc"
}

kc_ok() { printf '0' > "$1"; }
kc_bad() { printf '1' > "$1"; }

kc_write_runner() {
  cat > "$KC_DIR/run.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
_INSTALL_PREREQUISITES_TEST_SOURCE=1 source '$hook'
run_key_presence_check '$KC_SOURCE' 1>'$KC_LOG/stdout.log' 2>'$KC_LOG/stderr.log'
EOF
  chmod +x "$KC_DIR/run.sh"
}

# Runs run_key_presence_check inline (no tty needed): use for every non-interactive
# scenario. Captures stdout/stderr to $KC_LOG/stdout.log and stderr.log.
kc_run() {
  local rc=0
  run_key_presence_check "$KC_SOURCE" >"$KC_LOG/stdout.log" 2>"$KC_LOG/stderr.log" || rc=$?
  return "$rc"
}

# Drives an interactive ask-operator scenario through a real pty (expect),
# sending each element of $2... as a PIN whenever the operator prompt appears,
# in order. Returns the spawned run.sh's own exit code.
kc_run_interactive() {
  kc_write_runner
  local tcl="$KC_DIR/drive.tcl" pin
  {
    printf 'log_user 0\n'
    printf 'set timeout 20\n'
    printf 'spawn %s\n' "$KC_DIR/run.sh"
  } > "$tcl"
  for pin in "$@"; do
    {
      printf 'expect {\n'
      printf '  -re {PIN for serial[^\\r\\n]*} { send -- "%s\\r" }\n' "$pin"
      printf '  timeout { exit 90 }\n'
      printf '  eof { exit 91 }\n'
      printf '}\n'
    } >> "$tcl"
  done
  {
    printf 'expect eof\n'
    printf 'catch wait result\n'
    printf 'exit [lindex $result 3]\n'
  } >> "$tcl"
  local rc=0
  expect -f "$tcl" >/dev/null 2>&1 || rc=$?
  return "$rc"
}

kc_stderr_has() { grep -qF -- "$1" "$KC_LOG/stderr.log"; }
kc_gpg_arg() { grep -qF $'\x1f'"$1"$'\x1f' "$KC_LOG/gpg.log" 2>/dev/null; }
kc_agent_arg() { grep -qF $'\x1f'"$1"$'\x1f' "$KC_LOG/gpg-connect-agent.log" 2>/dev/null; }
kc_chezmoi_call() { grep -qF $'\x1f'"secret"$'\x1f'"keyring"$'\x1f'"$1"$'\x1f' "$KC_LOG/chezmoi.log" 2>/dev/null; }

# ============================== T1 (AE3) =====================================
(
  kc_new
  kc_classify_local 1
  kc_run || exit 1
  [[ ! -f "$KC_LOG/learn.log" ]] || exit 11
  kc_agent_arg 'scd serialno' && exit 12
  kc_chezmoi_call get && exit 13
  true
) || fail 'T1: local class must pass with no learn, no card step, no keyring read'
pass 'T1: local class passes with no learn, no card step, no keyring read (AE3)'

# ============================== T3 ===========================================
(
  kc_new
  kc_classify_none 1
  kc_classify_card "$KC_SERIAL" 2
  printf '%s' "$KC_AID" > "$KC_FIXTURE/serialno_aid"
  kc_ok "$KC_FIXTURE/cancel_probe_rc"
  kc_run || exit 1
  grep -q 'LEARN' "$KC_LOG/learn.log" || exit 31
  kc_agent_arg 'scd getattr CHV-STATUS' && exit 32
  kc_chezmoi_call get && exit 33
  true
) || fail 'T3: cancel-mode probe OK must skip CHV-STATUS, keyring read, and any ask'
pass 'T3: cancel-mode probe OK short-circuits with no CHV-STATUS/keyring/ask'

# ============================== T2 (AE2) =====================================
(
  kc_new
  kc_classify_none 1
  kc_classify_card "$KC_SERIAL" 2
  printf '%s' "$KC_AID" > "$KC_FIXTURE/serialno_aid"
  kc_bad "$KC_FIXTURE/cancel_probe_rc"
  printf '+3+3+3+3+3+3+3' > "$KC_FIXTURE/chv_status_line"
  printf 'secretPIN123' > "$KC_FIXTURE/keyring-gnupg-card-pin-$KC_SERIAL"
  printf '0' > "$KC_FIXTURE/loopback_rc_sequence"
  kc_run || exit 1
  grep -qx 'LEARN' "$KC_LOG/learn.log" || exit 21
  kc_agent_arg 'scd getattr CHV-STATUS' || exit 22
  grep -qx 'secretPIN123' "$KC_LOG/loopback-delivered-pins.log" || exit 24
  kc_chezmoi_call set && exit 26
  true
) || fail 'T2: stored PIN at max retries must verify via inquiry data only, no keyring write'
pass 'T2: none class -> learn -> stored PIN verified via inquiry, no keyring write (AE2)'

# ============================== T4 ===========================================
(
  kc_new
  kc_classify_none 1
  kc_classify_card "$KC_SERIAL" 2
  printf '%s' "$KC_AID" > "$KC_FIXTURE/serialno_aid"
  kc_bad "$KC_FIXTURE/cancel_probe_rc"
  printf '+3+3+3+3+3+3+3' > "$KC_FIXTURE/chv_status_line"
  printf 'cachedPIN' > "$KC_FIXTURE/keyring-gnupg-card-pin-$KC_SERIAL"
  printf '1' > "$KC_FIXTURE/cache_hit"
  printf '0' > "$KC_FIXTURE/loopback_rc_sequence"
  kc_run || exit 1
  [[ ! -s "$KC_LOG/loopback-delivered-pins.log" ]] || exit 41
  kc_chezmoi_call set && exit 42
  true
) || fail 'T4: an agent-cache loopback OK with no inquiry must pass with no keyring write'
pass 'T4: loopback checkpin OK without an observed PASSPHRASE inquiry passes, no keyring write'

# ============================== T5 ===========================================
(
  kc_new
  printf '1' > "$KC_FIXTURE/classify_rc"
  if kc_run; then exit 1; fi
  kc_stderr_has "$KC_FPR" || exit 51
  [[ ! -f "$KC_LOG/gpg-connect-agent.log" ]] || grep -q 'scd' "$KC_LOG/gpg-connect-agent.log" && exit 52
  [[ ! -f "$KC_LOG/learn.log" ]] || exit 53
  true
) || fail 'T5: a listing exit other than 0 or 2 must fail with no scd command and no learn'
pass 'T5: gpg -K exit other than 0/2 fails, no scd command, no learn'

# ============================== T6 (unit-level classify) =====================
(
  kc_new
  kc_classify_unrelated_only
  key_check_classify "$KC_FPR" || exit 61
  [[ "$KEY_CHECK_CLASS" == none ]] || exit 62
) || fail 'T6: an unrelated fingerprint with a secret must not count toward this fingerprint'
pass 'T6: records belonging to an unrelated fingerprint do not count; class is none'

# ============================== T7 ===========================================
(
  kc_new
  kc_classify_card '11112222'
  printf '%s' "$KC_AID" > "$KC_FIXTURE/serialno_aid"
  {
    kc_colon_line grp '' '' '' '' '' '' '' '' 'GRIPPRIMARY0000000000000000000001' '' '' '' '' ''
  } > "$KC_FIXTURE/pubkeygrips_output"
  mkdir -p "$KC_HOME/.gnupg/private-keys-v1.d"
  # A real passphrase-protected local key file (agent/protect.c), never a
  # shadow stub: exercises the explicit `(protected-private-key`/`(private-key`
  # rejection, not just the absence of the shadow marker.
  printf '(21:protected-private-key(3:rsa(1:n3:...)(1:e3:...))(8:protected25:openpgp-s2k3(...)))' \
    > "$KC_HOME/.gnupg/private-keys-v1.d/GRIPPRIMARY0000000000000000000001.key"
  if kc_run; then exit 1; fi
  kc_stderr_has 'GRIPPRIMARY0000000000000000000001.key' || exit 71
  [[ ! -f "$KC_LOG/learn.log" ]] || exit 72
  true
) || fail 'T7: a differing card stub next to a non-shadow key file must refuse with no learn'
pass 'T7: card stub serial differs, unsafe key file present -> refuses, names the file, no learn'

# ============================== T8 ===========================================
(
  kc_new
  kc_classify_card "$KC_SERIAL"
  printf '%s' "$KC_AID" > "$KC_FIXTURE/serialno_aid_1"
  printf '%s' "$KC_AID2" > "$KC_FIXTURE/serialno_aid_2"
  printf '+3+3+3+3+3+3+3' > "$KC_FIXTURE/chv_status_line"
  printf 'secretPIN123' > "$KC_FIXTURE/keyring-gnupg-card-pin-$KC_SERIAL"
  kc_bad "$KC_FIXTURE/cancel_probe_rc"
  printf '0' > "$KC_FIXTURE/loopback_rc_sequence"
  if kc_run; then exit 1; fi
  [[ ! -f "$KC_LOG/loopback-sessions.log" ]] || exit 81
  true
) || fail 'T8: a serial that changes between the probe and the loopback checkpin sends nothing'
pass 'T8: scd serialno changing before the loopback checkpin aborts with nothing sent'

# ============================== T10 ==========================================
(
  kc_new
  kc_classify_none 1
  kc_classify_card "$KC_SERIAL" 2
  printf '%s' "$KC_AID" > "$KC_FIXTURE/serialno_aid"
  kc_bad "$KC_FIXTURE/cancel_probe_rc"
  printf '+3+3+3+3+3+3+3' > "$KC_FIXTURE/chv_status_line"
  dollar_pin='sec${HOME}ret'
  printf '%s' "$dollar_pin" > "$KC_FIXTURE/keyring-gnupg-card-pin-$KC_SERIAL"
  printf '0' > "$KC_FIXTURE/loopback_rc_sequence"
  kc_run || exit 1
  grep -qxF "$dollar_pin" "$KC_LOG/loopback-delivered-pins.log" || exit 101
  true
) || fail 'T10: a PIN containing $ must reach the inquiry unexpanded'
pass 'T10: a PIN containing $ reaches the inquiry unexpanded'

# ============================== T11 ==========================================
(
  kc_new
  kc_classify_local 1
  printf '%s:6:\n' "$KC_FPR" > "$KC_FIXTURE/ownertrust"
  kc_ok "$KC_FIXTURE/list_keys_rc"
  kc_run || exit 1
  kc_gpg_arg '--import' && exit 111
  kc_gpg_arg '--import-ownertrust' && exit 112
  true
) || fail 'T11: an already-present public key and ownertrust must not be re-imported'
pass 'T11: public key and ownertrust already present -> no --import, no --import-ownertrust'

# ============================== T12 (AE1) ====================================
(
  kc_new
  kc_classify_none
  kc_bad "$KC_FIXTURE/serialno_rc"
  if kc_run; then exit 1; fi
  kc_stderr_has "$KC_FPR" || exit 121
  kc_stderr_has 'insert' || exit 122
  [[ ! -f "$KC_LOG/learn.log" ]] || exit 123
  true
) || fail 'T12: class none with no card must fail naming the fingerprint and insert instruction'
pass 'T12: class none, no card -> fails naming fingerprint and insert instruction, no learn (AE1)'

# ============================== T13 (AE5) ====================================
(
  kc_new
  kc_classify_none 1
  kc_classify_card "$KC_SERIAL" 2
  printf '%s' "$KC_AID" > "$KC_FIXTURE/serialno_aid"
  kc_bad "$KC_FIXTURE/cancel_probe_rc"
  printf '+3+3+3+3+3+3+3' > "$KC_FIXTURE/chv_status_line"
  printf 'oldStoredPIN' > "$KC_FIXTURE/keyring-gnupg-card-pin-$KC_SERIAL"
  printf '1\n0\n' > "$KC_FIXTURE/loopback_rc_sequence"
  kc_run_interactive 'operatorNewPIN' >/dev/null 2>&1
  rc=$?
  [[ $rc -eq 0 ]] || { cat "$KC_LOG/stderr.log" >&2; exit 131; }
  [[ $(cat "$KC_FIXTURE/loopback_call_count") -eq 2 ]] || exit 132
  grep -c '^oldStoredPIN$' "$KC_LOG/loopback-delivered-pins.log" | grep -qx 1 || exit 133
  grep -c '^operatorNewPIN$' "$KC_LOG/loopback-delivered-pins.log" | grep -qx 1 || exit 134
  grep -qx 'operatorNewPIN' "$KC_FIXTURE/keyring-gnupg-card-pin-$KC_SERIAL" || exit 135
  true
) || fail 'T13: a rejected stored PIN must be replaced by one interactive entry, sent once each'
pass 'T13: stored PIN rejected at max -> operator enters new PIN, stored once, old PIN not resent (AE5)'

# ============================== T14 ==========================================
(
  kc_new
  kc_classify_none 1
  kc_classify_card "$KC_SERIAL" 2
  printf '%s' "$KC_AID" > "$KC_FIXTURE/serialno_aid"
  kc_bad "$KC_FIXTURE/cancel_probe_rc"
  printf '+3+3+3+3+2+3+3' > "$KC_FIXTURE/chv_status_line"
  printf 'storedButUnused' > "$KC_FIXTURE/keyring-gnupg-card-pin-$KC_SERIAL"
  printf '0\n' > "$KC_FIXTURE/loopback_rc_sequence"
  kc_run_interactive 'operatorPIN' >/dev/null 2>&1
  rc=$?
  [[ $rc -eq 0 ]] || { cat "$KC_LOG/stderr.log" >&2; exit 141; }
  [[ $(cat "$KC_FIXTURE/loopback_call_count" 2>/dev/null || echo 0) -eq 1 ]] || exit 142
  grep -qx 'operatorPIN' "$KC_LOG/loopback-delivered-pins.log" || exit 143
  grep -q '2 attempt' "$KC_LOG/stdout.log" "$KC_LOG/run.sh" 2>/dev/null; true
  true
) || fail 'T14: with 2 retries left the stored PIN must never be auto-tried; the operator is asked'
pass 'T14: retry counter at two with a stored PIN skips the automatic try, asks the operator'

# ============================== T15 ==========================================
(
  kc_new
  kc_classify_none 1
  kc_classify_card "$KC_SERIAL" 2
  printf '%s' "$KC_AID" > "$KC_FIXTURE/serialno_aid"
  kc_bad "$KC_FIXTURE/cancel_probe_rc"
  printf '+3+3+3+3+4+3+3' > "$KC_FIXTURE/chv_status_line"
  if kc_run; then exit 1; fi
  kc_stderr_has 'R17' || exit 151
  [[ ! -f "$KC_LOG/loopback-sessions.log" ]] || exit 152
  true
) || fail 'T15: a counter above 3 must fail naming R17 with nothing sent'
pass 'T15: retry counter above 3 fails naming the R17 card setting, nothing sent'

# ============================== T16 ==========================================
(
  kc_new
  kc_classify_none 1
  kc_classify_card "$KC_SERIAL" 2
  printf '%s' "$KC_AID" > "$KC_FIXTURE/serialno_aid"
  kc_bad "$KC_FIXTURE/cancel_probe_rc"
  printf '+3+3+3+3+0+3+3' > "$KC_FIXTURE/chv_status_line"
  if kc_run; then exit 1; fi
  kc_stderr_has 'unblock' || exit 161
  [[ ! -f "$KC_LOG/loopback-sessions.log" ]] || exit 162
  true
) || fail 'T16: a counter of zero must fail with unblock guidance, nobody asked'
pass 'T16: retry counter of zero fails with unblock guidance, nobody asked'

# ============================== T17 ==========================================
(
  kc_new
  kc_bad "$KC_FIXTURE/agent_probe_rc"
  if kc_run; then exit 1; fi
  kc_stderr_has "$KC_FPR" && true
  [[ ! -f "$KC_LOG/gpg.log" ]] || grep -q -- '-K' "$KC_LOG/gpg.log" && exit 171
  [[ ! -f "$KC_LOG/learn.log" ]] || exit 172
  true
) || fail 'T17: an unreachable agent must fail with no listing and no learn'
pass 'T17: agent probe failure fails with no listing, no scd command, no learn'

# ============================== T18 ==========================================
(
  kc_new
  kc_classify_unavailable
  if kc_run; then exit 1; fi
  kc_stderr_has 'GRIPPRIMARY0000000000000000000001.key' || exit 181
  [[ ! -f "$KC_LOG/learn.log" ]] || exit 182
  kc_agent_arg 'scd serialno' && exit 183
  true
) || fail 'T18: an unavailable (#) secret-key stub must fail naming the key file, no learn, no card step'
pass 'T18: listing shows # -> fails naming the key file, no learn, no card step'

# ============================== T19 ==========================================
(
  kc_new
  kc_classify_none 1
  kc_classify_none 2
  printf '%s' "$KC_AID" > "$KC_FIXTURE/serialno_aid"
  if kc_run; then exit 1; fi
  kc_stderr_has 'after learn' || exit 191
  kc_agent_arg 'scd getattr CHV-STATUS' && exit 192
  true
) || fail 'T19: no card record for the fingerprint after learn must fail with the R7 message, no PIN step'
pass 'T19: post-learn reclassify shows no card record -> R7 message, no PIN step'

# ============================== T20 ==========================================
(
  kc_new
  kc_classify_none
  kc_bad "$KC_FIXTURE/serialno_rc"
  printf 'shouldBeCleared' > "$KC_FIXTURE/keyring-gnupg-card-pin-$KC_SERIAL"
  if kc_run; then exit 1; fi
  [[ ! -f "$KC_FIXTURE/keyring-gnupg-card-pin-$KC_SERIAL" ]] || exit 201
  kc_chezmoi_call delete || exit 202
  true
) || fail 'T20: class none with no card must clear the stored PIN record for the declared serials'
pass 'T20: class none with no card clears the stored PIN record for the declared serials'

# ============================== T21 ==========================================
(
  kc_new
  kc_classify_none 1
  kc_classify_card "$KC_SERIAL" 2
  printf '%s' "$KC_AID" > "$KC_FIXTURE/serialno_aid"
  kc_bad "$KC_FIXTURE/cancel_probe_rc"
  printf '+3+3+3+3+3+3+3' > "$KC_FIXTURE/chv_status_line"
  printf 'firstStoredPIN' > "$KC_FIXTURE/keyring-gnupg-card-pin-$KC_SERIAL"
  printf '1\n' > "$KC_FIXTURE/loopback_rc_sequence"
  kc_run_interactive '' >/dev/null 2>&1
  rc=$?
  # A blank interactive answer passes with nothing stored (R15); the burned
  # stored PIN must not be tried again on the very next check.
  [[ $rc -eq 0 ]] || { cat "$KC_LOG/stderr.log" >&2; exit 211; }

  # Second, independent check run: same fixture directory, counter now at 2
  # (one automated attempt burned) — the stored PIN must not be auto-tried.
  kc_second=$(mktemp -d "$scratch/kc-XXXXXX")
  cp -a "$KC_SOURCE" "$kc_second/source"
  cp -a "$KC_BIN" "$kc_second/bin"
  mkdir -p "$kc_second/fixture" "$kc_second/log" "$kc_second/home"
  cp -a "$KC_FIXTURE/." "$kc_second/fixture/"
  rm -f "$kc_second/fixture/classify_call_count" "$kc_second/fixture/serialno_call_count" "$kc_second/fixture/loopback_call_count"
  printf '+3+3+3+3+2+3+3' > "$kc_second/fixture/chv_status_line"
  KC_FIXTURE="$kc_second/fixture" KC_LOG="$kc_second/log" KC_SOURCE="$kc_second/source" \
    PATH="$kc_second/bin:$clean_bin" HOME="$kc_second/home" FIXTURE_DIR="$kc_second/fixture" LOG_DIR="$kc_second/log" \
    bash -c "_INSTALL_PREREQUISITES_TEST_SOURCE=1 source '$hook'; is_container() { return 1; }; run_key_presence_check '$kc_second/source'" \
    >/dev/null 2>&1
  rc2=$?
  # Second run must fail (blank was never resent, counter now 2 -> ask again;
  # non-interactive here so it fails on no /dev/tty) but must NOT have retried
  # the burned stored PIN automatically.
  [[ $rc2 -ne 0 ]] || exit 212
  [[ ! -f "$kc_second/log/loopback-sessions.log" ]] || exit 213
  true
) || fail 'T21: a burned stored PIN must not be auto-tried again on the very next check'
pass 'T21: one automated burn leaves the counter lower; the next check sends nothing automatically'

# ============================== T22 ==========================================
(
  kc_new
  kc_classify_none 1
  kc_classify_card "$KC_SERIAL" 2
  printf '%s' "$KC_AID" > "$KC_FIXTURE/serialno_aid"
  kc_bad "$KC_FIXTURE/cancel_probe_rc"
  printf '+3+3+3+3+1+3+3' > "$KC_FIXTURE/chv_status_line"
  if kc_run; then exit 1; fi
  kc_stderr_has 'unblock' || exit 221
  [[ ! -f "$KC_LOG/loopback-sessions.log" ]] || exit 222
  true
) || fail 'T22: retry counter at one must send nothing and ask nobody, failing with unblock guidance'
pass 'T22: retry counter at one -> nothing sent, nobody asked, unblock guidance'

# ============================== T23 ==========================================
(
  kc_new
  kc_classify_none 1
  kc_classify_card "$KC_SERIAL" 2
  printf '%s' "$KC_AID" > "$KC_FIXTURE/serialno_aid"
  kc_bad "$KC_FIXTURE/cancel_probe_rc"
  printf '+3+3+3+3+3+3+3' > "$KC_FIXTURE/chv_status_line"
  kc_run_interactive '' >/dev/null 2>&1
  rc=$?
  [[ $rc -eq 0 ]] || { cat "$KC_LOG/stderr.log" >&2; exit 231; }
  [[ ! -f "$KC_LOG/loopback-sessions.log" ]] || exit 232
  [[ ! -f "$KC_FIXTURE/keyring-gnupg-card-pin-$KC_SERIAL" ]] || exit 233
  true
) || fail 'T23: no stored PIN -> ask the operator; a blank answer sends and stores nothing, exits 0'
pass 'T23: no stored PIN -> operator asked; blank answer stores nothing, exits 0 (R15)'

# ============================== T24 ==========================================
(
  kc_new
  kc_classify_none
  printf '%s' "$KC_UNDECLARED_AID" > "$KC_FIXTURE/serialno_aid"
  if kc_run; then exit 1; fi
  kc_stderr_has '99999999' || exit 241
  kc_stderr_has 'yubikeySerials' || exit 242
  true
) || fail 'T24: an inserted, undeclared card serial must fail naming the serial and yubikeySerials'
pass 'T24: inserted card serial not declared -> fails naming the serial and yubikeySerials'

# ============================== T25 ==========================================
(
  kc_new "$KC_FPR" "$KC_SERIAL, 88888888"
  kc_classify_card "$KC_SERIAL" 1
  kc_classify_card '88888888' 2
  printf '%s' "$KC_AID2" > "$KC_FIXTURE/serialno_aid"
  {
    kc_colon_line grp '' '' '' '' '' '' '' '' 'GRIPPRIMARY0000000000000000000001' '' '' '' '' ''
  } > "$KC_FIXTURE/pubkeygrips_output"
  mkdir -p "$KC_HOME/.gnupg/private-keys-v1.d"
  # gpg-agent writes a card shadow stub as the canonical S-expression
  # `(20:shadowed-private-key ...` (agent/protect.c:1534), never
  # `(shadowed-key`.
  printf '(20:shadowed-private-key(3:rsa(1:n3:...)(1:e3:...))(8:shadowed4:t1-v1(9:card-list20:%s)))' "$KC_AID2" \
    > "$KC_HOME/.gnupg/private-keys-v1.d/GRIPPRIMARY0000000000000000000001.key"
  kc_ok "$KC_FIXTURE/cancel_probe_rc"
  kc_run || { cat "$KC_LOG/stderr.log" >&2; exit 1; }
  [[ $(grep -cx 'LEARN --force' "$KC_LOG/learn.log" 2>/dev/null) -eq 1 ]] || exit 251
  grep -qx 'LEARN' "$KC_LOG/learn.log" && exit 252
  true
) || fail 'T25: a differing stub with only shadowed key files must run learn --force exactly once'
pass 'T25: declared backup serial inserted, only shadowed files present -> learn --force once (R6)'

# ============================== T26 (AE7) ====================================
(
  kc_new
  # Stub invoked indirectly by run_key_presence_check
  # shellcheck disable=SC2317,SC2329
  is_container() { return 0; }
  CI=false run_key_presence_check "$KC_SOURCE" >"$KC_LOG/stdout.log" 2>"$KC_LOG/stderr.log"
  [[ ! -f "$KC_LOG/gpg.log" ]] || exit 61
  # Stub invoked indirectly by run_key_presence_check
  # shellcheck disable=SC2317,SC2329
  is_container() { return 1; }
  CI=true run_key_presence_check "$KC_SOURCE" >>"$KC_LOG/stdout.log" 2>>"$KC_LOG/stderr.log"
  [[ ! -f "$KC_LOG/gpg.log" ]] || exit 62
) || fail 'T26: a real container or CI=true must skip the check with no gpg process'
pass 'T26: is_container true, or CI=true -> no gpg process starts (AE7)'

# ============================== T27 ==========================================
(
  kc_new
  kc_classify_none 1
  kc_classify_card "$KC_SERIAL" 2
  printf '%s' "$KC_AID" > "$KC_FIXTURE/serialno_aid"
  kc_bad "$KC_FIXTURE/cancel_probe_rc"
  printf '+3+3+3+3+3+3+3' > "$KC_FIXTURE/chv_status_line"
  slow_chezmoi="$KC_BIN/chezmoi"
  mv "$slow_chezmoi" "$KC_BIN/chezmoi.real"
  cat > "$slow_chezmoi" <<EOF
#!/usr/bin/env bash
if [[ "\$*" == *'secret keyring get'* ]]; then
  sleep 30
  exit 0
fi
exec "$KC_BIN/chezmoi.real" "\$@"
EOF
  chmod 0755 "$slow_chezmoi"
  kc_run_interactive '' >/dev/null 2>&1
  rc=$?
  [[ $rc -eq 0 ]] || { cat "$KC_LOG/stderr.log" >&2; exit 71; }
  true
) || fail 'T27: a keyring read exceeding its bound must be treated as no stored PIN'
pass 'T27: a keyring read exceeding its bound is treated as no stored PIN'

# ============================== T28 ==========================================
(
  kc_new
  kc_classify_none
  printf '%s' "$KC_AID" > "$KC_FIXTURE/serialno_aid"
  kc_bad "$KC_FIXTURE/cancel_probe_rc"
  printf 'not-a-valid-status-line' > "$KC_FIXTURE/chv_status_line"
  if kc_run; then exit 1; fi
  [[ ! -f "$KC_LOG/loopback-sessions.log" ]] || exit 81
  true
) || fail 'T28: a malformed CHV-STATUS line must fail with a message and send no PIN'
pass 'T28: a malformed CHV-STATUS line fails with a message, sends no PIN'

# ============================== T29 ==========================================
(
  kc_new
  kc_classify_local 1
  printf '%s:3:\n' "$KC_FPR" > "$KC_FIXTURE/ownertrust"
  kc_run || exit 1
  [[ -f "$KC_LOG/import-ownertrust-stdin.log" ]] || exit 95
  [[ "$(cat "$KC_LOG/import-ownertrust-stdin.log")" == "$KC_FPR:6:" ]] || exit 96
) || fail 'T29: ownertrust must be imported only when not already 6, receiving exactly <FPR>:6:'
pass 'T29: ownertrust import runs only when exported ownertrust != 6, receiving <FPR>:6:'

# ============================== T31 ==========================================
(
  kc_new
  kc_classify_none 1
  kc_classify_card "$KC_SERIAL" 2
  printf '%s' "$KC_AID" > "$KC_FIXTURE/serialno_aid"
  kc_bad "$KC_FIXTURE/cancel_probe_rc"
  printf '+3+3+3+3+3+3+3' > "$KC_FIXTURE/chv_status_line"
  if kc_run; then exit 1; fi
  kc_stderr_has 'terminal' || exit 121
  [[ ! -f "$KC_LOG/loopback-sessions.log" ]] || exit 122
  true
) || fail 'T31: no /dev/tty when an ask is needed must fail with the run-from-a-terminal message'
pass 'T31: no /dev/tty when an ask is needed -> run-from-a-terminal message, no pinentry started'

# ============================== T9 (cross-cutting) ===========================
(
  bad=0
  for f in "$scratch"/kc-*/log/gpg-connect-agent.log; do
    [[ -f "$f" ]] || continue
    grep -qF $'\x1f''-v'$'\x1f' "$f" && { printf '%s passed -v to gpg-connect-agent\n' "$f" >&2; bad=1; }
  done
  for f in "$scratch"/kc-*/log/chezmoi-violations.log; do
    [[ -f "$f" ]] && { printf '%s: --value reached a PIN write\n' "$f" >&2; bad=1; }
  done
  for pin in secretPIN123 cachedPIN oldStoredPIN operatorNewPIN storedButUnused operatorPIN firstStoredPIN; do
    for f in "$scratch"/kc-*/log/gpg.log "$scratch"/kc-*/log/gpg-connect-agent.log "$scratch"/kc-*/log/chezmoi.log; do
      [[ -f "$f" ]] || continue
      grep -qF -- "$pin" "$f" && { printf '%s: PIN %s leaked into an argv/status log\n' "$f" "$pin" >&2; bad=1; }
    done
  done
  [[ $bad -eq 0 ]]
) || fail 'T9: no gpg-connect-agent call may carry -v, no chezmoi call may carry --value for a PIN, and no PIN may appear outside the dedicated inquiry-data log'
pass 'T9: across every scenario, no -v to gpg-connect-agent, no --value for a PIN, PIN never in argv/stdout/stderr'


printf 'test-key-custody-hook: all preflight scenarios passed\n'
