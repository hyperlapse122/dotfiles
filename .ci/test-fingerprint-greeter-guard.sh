#!/usr/bin/env bash
# Prove the predicate that keeps the login greeter password-only.
#
# `authselect enable-feature with-fingerprint` writes pam_fprintd into
# system-auth, which /etc/pam.d/sudo and /usr/lib/pam.d/polkit-1 both include --
# AGENTS.md records that this repository accepts the factor there. What it does
# NOT accept is the factor reaching the LOGIN GREETER, and
# greeter_would_gain_fingerprint is the single control enforcing that. It runs
# before the feature is enabled, against the profile authselect WOULD render, so
# nothing on a real host can exercise it after the fact.
#
# The rule the cases below pin: only a stack that was actually READ may enable
# the factor. "Could not determine" resolves the same way an unrecognized display
# manager does -- by withholding. An earlier version failed OPEN here, and a
# second one aborted the whole installer under `set -u` before the guard ran.
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
scratch_root="${XDG_RUNTIME_DIR:-$HOME/.cache}/agent-scratch"
mkdir -p -- "$scratch_root"
scratch=$(mktemp -d "$scratch_root/fingerprint-greeter-guard.XXXXXX")
trap 'rm -rf -- "$scratch"' EXIT

fail() {
  printf 'fingerprint-greeter-guard: FAIL: %s\n' "$*" >&2
  exit 1
}

# Render the installer the way CI does: never against the live $HOME.
printf '' >"$scratch/empty.toml"
mkdir -p "$scratch/target"
rendered="$scratch/install-system-fingerprint.sh"
chezmoi --config "$scratch/empty.toml" --source "$repo_root" \
  --destination "$scratch/target" \
  --override-data '{"chezmoi":{"os":"linux","arch":"amd64","username":"fixture","osRelease":{"id":"fedora"}}}' \
  execute-template <"$repo_root/.chezmoiscripts/30-linux/run_onchange_after_install-system-32-fingerprint.sh.tmpl" \
  >"$rendered" 2>"$scratch/render.err" \
  || { cat "$scratch/render.err" >&2; fail 'the fingerprint installer did not render'; }
bash -n "$rendered" || fail 'the rendered fingerprint installer is not valid bash'

# Extract only the predicate and its helpers. Anchored ranges fail silently when
# a name changes, so every one is asserted present.
helpers="$scratch/helpers.sh"
sed -n '/^pam_service_file()/,/^}/p;/^pam_chain_has_fprintd()/,/^}/p;/^pam_auth_includes()/,/^}/p;/^greeter_service()/,/^}/p;/^greeter_would_gain_fingerprint()/,/^}/p' \
  "$rendered" >"$helpers"
for fn in pam_service_file pam_chain_has_fprintd pam_auth_includes \
  greeter_service greeter_would_gain_fingerprint; do
  grep -q "^${fn}()" "$helpers" || fail "${fn} was not extracted from the rendered installer"
done

# --- synthetic PAM trees ----------------------------------------------------
pam_file() {
  local root=$1 service=$2
  mkdir -p "$root/etc/pam.d"
  cat >"$root/etc/pam.d/$service"
}

# Drive the predicate with the absolute PAM paths rewritten to a fake root and a
# stubbed authselect. AUTHSELECT_OUT is what `authselect test` prints; empty
# means the call failed, which is the "cannot be asked" path.
verdict_under() {
  local root=$1 profile=$2 out_file=$3 dm=$4
  local driver="$scratch/driver.sh"
  {
    printf 'set -uo pipefail\n'
    printf 'FACT_DISPLAY_MANAGER=%q\n' "$dm"
    printf 'AUTHSELECT_FEATURES=(with-fingerprint)\n'
    printf 'AUTHSELECT_PROFILE=%q\n' "$profile"
    printf 'AUTHSELECT_OUT=%q\n' "$out_file"
    # Stand in for `"${SUDO[@]}" authselect ...` and `"${SUDO[@]}" env ... authselect ...`.
    cat <<'STUB'
authselect() {
  case "${1-}" in
    current) [[ -n "$AUTHSELECT_PROFILE" ]] && printf '%s\n' "$AUTHSELECT_PROFILE"; [[ -n "$AUTHSELECT_PROFILE" ]] ;;
    test)    [[ -n "$AUTHSELECT_OUT" && -r "$AUTHSELECT_OUT" ]] && cat "$AUTHSELECT_OUT"; [[ -n "$AUTHSELECT_OUT" && -r "$AUTHSELECT_OUT" ]] ;;
    *)       return 1 ;;
  esac
}
env() { while [[ "${1-}" == *=* ]]; do shift; done; "$@"; }
SUDO=()
STUB
    sed -e "s#\"/etc/pam.d/#\"${root}/etc/pam.d/#g" \
        -e "s#\"/usr/lib/pam.d/#\"${root}/usr/lib/pam.d/#g" \
        -e 's#File /etc/pam.d/#File /etc/pam.d/#g' "$helpers"
    printf 'if greeter_would_gain_fingerprint; then printf withhold; else printf enable; fi\n'
  } >"$driver"
  bash "$driver" 2>/dev/null
}

expect() {
  local want=$1 got=$2 what=$3
  [[ "$got" == "$want" ]] || fail "$what: expected $want, got '${got:-<empty, the predicate crashed>}'"
}

# --- case 1: the greeter's stack is clean -> enable --------------------------
clean="$scratch/clean"
pam_file "$clean" plasmalogin <<'PAM'
auth       substack     password-auth
auth       include      postlogin
PAM
pam_file "$clean" password-auth <<'PAM'
auth       required     pam_env.so
auth       sufficient   pam_unix.so nullok
PAM
cat >"$scratch/clean.authselect" <<'OUT'
File /etc/pam.d/system-auth:
auth        sufficient                                   pam_fprintd.so
auth        sufficient                                   pam_unix.so nullok
File /etc/pam.d/password-auth:
auth        required                                     pam_env.so
auth        sufficient                                   pam_unix.so nullok
OUT
expect enable "$(verdict_under "$clean" 'local with-fingerprint' "$scratch/clean.authselect" plasmalogin)" \
  'a greeter whose rendered stacks carry no fingerprint module must ENABLE'

# --- case 2: the greeter's own stack would gain the factor -> withhold -------
dirty="$scratch/dirty"
pam_file "$dirty" plasmalogin <<'PAM'
auth       substack     password-auth
PAM
pam_file "$dirty" password-auth <<'PAM'
auth       required     pam_env.so
PAM
cat >"$scratch/dirty.authselect" <<'OUT'
File /etc/pam.d/system-auth:
auth        sufficient                                   pam_fprintd.so
File /etc/pam.d/password-auth:
auth        required                                     pam_env.so
auth        sufficient                                   pam_fprintd.so
OUT
expect withhold "$(verdict_under "$dirty" 'local with-fingerprint' "$scratch/dirty.authselect" plasmalogin)" \
  'a greeter whose rendered stack gains pam_fprintd must WITHHOLD'

# --- case 3: unrecognized display manager -> withhold ------------------------
expect withhold "$(verdict_under "$clean" 'local with-fingerprint' "$scratch/clean.authselect" lightdm)" \
  'an unrecognized display manager must WITHHOLD'
expect withhold "$(verdict_under "$clean" 'local with-fingerprint' "$scratch/clean.authselect" '')" \
  'an unresolved display manager must WITHHOLD'

# --- case 4: authselect cannot be asked -------------------------------------
# The predicate must not crash (an unset `rendered` under set -u aborted the whole
# installer here), and with no rendered profile it falls back to the live chain.
expect enable "$(verdict_under "$clean" '' '' plasmalogin)" \
  'no authselect profile, and a live greeter chain with no fingerprint module, must ENABLE without crashing'

livedirty="$scratch/livedirty"
pam_file "$livedirty" plasmalogin <<'PAM'
auth       substack     password-auth
PAM
pam_file "$livedirty" password-auth <<'PAM'
auth       sufficient   pam_fprintd.so
PAM
expect withhold "$(verdict_under "$livedirty" '' '' plasmalogin)" \
  'no authselect profile, but a live greeter chain that already reaches pam_fprintd, must WITHHOLD'

# --- case 5: the greeter's PAM file cannot be resolved at all -> withhold ----
# THE FAIL-OPEN THIS FILE EXISTS FOR. Nothing was read, so nothing may be
# concluded, and the repository's fail-safe rule makes that a withhold.
missing="$scratch/missing"
mkdir -p "$missing/etc/pam.d"
expect withhold "$(verdict_under "$missing" 'local with-fingerprint' "$scratch/clean.authselect" plasmalogin)" \
  'a greeter whose PAM file does not exist must WITHHOLD, not enable'

# --- case 6: the greeter includes a stack authselect does not manage ---------
# authselect renders no section by that name, so the primary check gets no
# answer and must not read "no answer" as "clean".
unmanaged="$scratch/unmanaged"
pam_file "$unmanaged" plasmalogin <<'PAM'
auth       substack     vendor-private-auth
PAM
pam_file "$unmanaged" vendor-private-auth <<'PAM'
auth       sufficient   pam_fprintd.so
PAM
expect withhold "$(verdict_under "$unmanaged" 'local with-fingerprint' "$scratch/clean.authselect" plasmalogin)" \
  'a greeter reaching an authselect-unmanaged stack that carries pam_fprintd must WITHHOLD'

printf 'fingerprint-greeter-guard: OK\n'
