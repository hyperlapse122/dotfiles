#!/usr/bin/env bash
# Prove the sudo elevation ladder, in both halves it has.
#
# RENDER half: the guard resolves its askpass helper at render time from the
# `desktop` fact, so there are three shapes and each must be checked. `none`
# renders no helper and no rung at all, because a SUDO_ASKPASS pointing at an
# absent binary is a new failure surface. All three must reach the declared exit
# through a byte-identical enclosing condition, or .ci/skip-declaration-site-matrix.yaml
# cannot store one predicate that holds on every render host — the CI runners
# have no desktop binaries and would pin the `none` shape, while a KDE
# workstation renders a different one.
#
# BEHAVIOUR half: the ladder is runtime logic, so the rendered shell is executed
# with a stub `sudo` on PATH. The helper is named by ABSOLUTE path, so a PATH
# stub cannot substitute it; the behaviour fixture rewrites that literal to a
# scratch path instead. The literal itself is proven by the render half, so
# nothing is left unchecked by the split.
#
# The 120-second bound is likewise rewritten to one second in the behaviour
# fixture. Waiting out the real bound would add two minutes to CI to prove a
# code path a one-second bound proves identically.
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=.ci/lib/render-gate-helpers.sh
source "$repo_root/.ci/lib/render-gate-helpers.sh"

scratch_root="${XDG_RUNTIME_DIR:-$HOME/.cache}/agent-scratch"
mkdir -p -- "$scratch_root"
scratch=$(mktemp -d "$scratch_root/sudo-elevation-guard.XXXXXX")
trap 'rm -rf -- "$scratch"' EXIT
mkdir -p "$scratch/home" "$scratch/bin" "$scratch/target" "$scratch/state" "$scratch/src/.chezmoitemplates"
printf '[data]\n' >"$scratch/empty.toml"

fail() { printf 'sudo-elevation-guard: FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'sudo-elevation-guard: ok - %s\n' "$*"; }

chezmoi_bin=$(type -P chezmoi) || fail 'chezmoi is required on PATH'

require_file "$repo_root" "$scratch" "$chezmoi_bin" .chezmoitemplates/sudo-elevation-guard.sh.tmpl
guard_src="$repo_root/.chezmoitemplates/sudo-elevation-guard.sh.tmpl"
cp "$repo_root/.chezmoitemplates/skip.sh.tmpl" "$scratch/src/.chezmoitemplates/"

# A consumer that uses the SUDO array, so shellcheck sees the array consumed the
# way a real provisioning script consumes it.
cat >"$scratch/consumer.tmpl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
{{ includeTemplate "sudo-elevation-guard.sh.tmpl" (dict "ctx" . "name" "probe-script") }}
"${SUDO[@]}" install -d -m 0755 /etc/probe.d
EOF

# The fixture source tree carries a fact-pinned copy of the production partial,
# so one render exercises the real guard at a chosen `desktop` value.
render_guard() {
  local desktop=$1 output=$2
  write_fact_stub "$guard_src" "$scratch/src/.chezmoitemplates/sudo-elevation-guard.sh.tmpl" \
    false false "$desktop"
  render "$scratch/src" "$scratch" "$chezmoi_bin" linux "$scratch/consumer.tmpl" "$output"
}

# ---- Render half ------------------------------------------------------------

for desktop in kde gnome none; do
  render_guard "$desktop" "$scratch/render-$desktop.sh" \
    || fail "the $desktop shape does not render"
  bash -n "$scratch/render-$desktop.sh" || fail "the $desktop shape is not valid shell"
  if command -v shellcheck >/dev/null 2>&1; then
    shellcheck -S warning "$scratch/render-$desktop.sh" \
      || fail "the $desktop shape fails shellcheck"
  fi
done
pass 'all three desktop shapes render, parse, and pass shellcheck'

grep -q "SUDO_ASKPASS='/usr/bin/ksshaskpass'" "$scratch/render-kde.sh" \
  || fail 'the kde shape does not name ksshaskpass'
grep -q "SUDO_ASKPASS='/usr/libexec/openssh/gnome-ssh-askpass'" "$scratch/render-gnome.sh" \
  || fail 'the gnome shape does not name gnome-ssh-askpass'
grep -q 'SUDO_ASKPASS' "$scratch/render-none.sh" \
  && fail 'the none shape names an askpass helper; it must render the rung away'
grep -q 'sudo -A' "$scratch/render-none.sh" \
  && fail 'the none shape reaches sudo -A; it must render the rung away'
pass 'each shape names its own helper, and none names no helper at all'

for desktop in kde gnome none; do
  count=$(grep -c 'skip-declaration-v1 owner=sudo-elevation-guard/no-elevation-path' \
    "$scratch/render-$desktop.sh" || true)
  [[ "$count" == 1 ]] || fail "the $desktop shape carries $count declarations, expected 1"
  grep -q 'direction=transient-tolerable' "$scratch/render-$desktop.sh" \
    || fail "the $desktop shape does not declare transient-tolerable"
  grep -q 'exit=exit-1' "$scratch/render-$desktop.sh" \
    || fail "the $desktop shape does not declare a non-zero exit"
  grep -q 'probe=none' "$scratch/render-$desktop.sh" \
    || fail "the $desktop shape names a probe; transient-tolerable must name none"
done
pass 'every shape declares exactly one transient-tolerable exit-1 site with no probe'

# The matrix stores ONE predicate for this owner. If the enclosing condition
# differed by desktop, the oracle would pass on the render host that happened to
# produce the pinned shape and fail on every other.
predicates=$(for desktop in kde gnome none; do
  grep -F 'sudo_elevation_ready" -ne 1' "$scratch/render-$desktop.sh"
done | sort -u | wc -l)
[[ "$predicates" == 1 ]] \
  || fail "the declared exit sits behind $predicates distinct conditions; the matrix stores one"
pass 'the declared exit sits behind one byte-identical condition in every shape'

grep -q 'ssh -t' "$scratch/render-kde.sh" \
  || fail 'the failure message does not name the terminal remedy'
grep -q 'sudo -v' "$scratch/render-kde.sh" \
  || fail 'the failure message does not name the authenticate-first remedy'
pass 'the failure message names an action that would let the run elevate'

grep -q 'if \[\[ "${EUID}" -eq 0 \]\]; then' "$scratch/render-none.sh" \
  || fail 'the ladder does not start at the already-root rung'
pass 'the ladder starts at the already-root rung'

# The behaviour half rewrites this bound down to one second. Pin the production
# value here so widening it is caught by the render half rather than silently
# rewritten and asserted as bounded.
grep -q 'timeout -k 5 120 sudo -A -v' "$scratch/render-kde.sh" \
  || fail 'the askpass rung no longer carries the 120-second bound'
pass 'the askpass rung carries its production bound'

grep -q 'if command -v sudo >/dev/null 2>&1; then' "$scratch/render-none.sh" \
  || fail 'the ladder does not gate its rungs on the sudo binary'
pass 'rungs 2 to 4 sit behind the sudo binary check'

# ---- Behaviour half ---------------------------------------------------------

# Rewrite the two literals a test cannot otherwise reach: the absolute helper
# path and the 120-second bound.
behaviour_fixture() {
  local shape=$1 output=$2
  sed -e "s@SUDO_ASKPASS='[^']*'@SUDO_ASKPASS='$scratch/bin/askpass-stub'@" \
      -e 's@timeout -k 5 120 sudo -A -v@timeout -k 1 1 sudo -A -v@' \
      "$scratch/render-$shape.sh" \
    | grep -v 'install -d -m 0755 /etc/probe.d' >"$output"
  # Report the resolved state in place of the consumer's privileged call.
  {
    printf 'declare -p SUDO\n'
    printf 'printf "ready=%%s\\n" "${sudo_elevation_ready:-na}"\n'
  } >>"$output"
}

write_sudo_stub() {
  # $1: exit status for `sudo -n true`; $2: behaviour for `sudo -A -v`
  cat >"$scratch/bin/sudo" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == "-n" ]]; then exit $1; fi
if [[ "\$1" == "-A" ]]; then
  # Real sudo reads the helper named by SUDO_ASKPASS. Requiring it here is what
  # makes the gate fail if the guard ever stops exporting the variable.
  [[ -x "\${SUDO_ASKPASS:-}" ]] || exit 1
  "\$SUDO_ASKPASS" >/dev/null || exit 1
  $2
fi
exit 0
EOF
  chmod 700 "$scratch/bin/sudo"
}

printf '#!/usr/bin/env bash\nprintf secret\n' >"$scratch/bin/askpass-stub"
chmod 700 "$scratch/bin/askpass-stub"

# The PATH the ladder runs under. Every scenario but one uses the stub bin ahead
# of the real system directories; the no-sudo scenario swaps in a hermetic bin
# instead, because removing the stub while /usr/bin stays on PATH does not
# produce a host without sudo — it produces a host with the REAL one, and on a
# runner with passwordless sudo that resolves the ladder at rung 2.
ladder_path="$scratch/bin:/usr/bin:/bin"

run_ladder() {
  local fixture=$1
  shift
  # XDG_STATE_HOME is isolated as well as HOME: the declared exit writes a skip
  # record, and on a host that sets that variable an unisolated run would land it
  # in the operator's real ledger.
  env -u WAYLAND_DISPLAY -u DISPLAY "$@" \
    PATH="$ladder_path" HOME="$scratch/home" \
    XDG_STATE_HOME="$scratch/state" \
    bash "$fixture" </dev/null 2>&1
}

# A bin directory with no sudo in it, carrying only what the guard's failure path
# actually runs: bash (env resolves the interpreter through the new PATH too),
# plus the mkdir and rm the declared exit shells out to.
mkdir -p "$scratch/nosudo-bin"
for tool in bash mkdir rm; do
  ln -sf "$(command -v "$tool")" "$scratch/nosudo-bin/$tool"
done
[[ ! -e "$scratch/nosudo-bin/sudo" ]] || fail 'the hermetic bin must not contain sudo'

behaviour_fixture kde "$scratch/behave-kde.sh"
behaviour_fixture none "$scratch/behave-none.sh"

write_sudo_stub 0 'exit 0'
out=$(run_ladder "$scratch/behave-kde.sh") \
  || fail "the cached-credential rung failed: $out"
grep -q 'ready=1' <<<"$out" || fail "the cached-credential rung did not resolve: $out"
grep -q '\[1\]="-A"' <<<"$out" && fail "the cached-credential rung reached the askpass rung: $out"
pass 'a cached credential resolves the ladder without reaching the helper'

write_sudo_stub 1 'exit 0'
out=$(run_ladder "$scratch/behave-kde.sh" DISPLAY=:0) \
  || fail "the askpass rung failed: $out"
grep -q 'ready=1' <<<"$out" || fail "the askpass rung did not resolve: $out"
grep -q '\[1\]="-A"' <<<"$out" || fail "the askpass rung did not set sudo -A: $out"
pass 'with no terminal and a usable helper, the ladder resolves through sudo -A'

write_sudo_stub 1 'sleep 30'
start=$SECONDS
if run_ladder "$scratch/behave-kde.sh" DISPLAY=:0 >/dev/null; then
  fail 'an unanswered dialog resolved the ladder'
fi
elapsed=$(( SECONDS - start ))
(( elapsed < 15 )) || fail "the unanswered dialog was not bounded (took ${elapsed}s)"
pass 'an unanswered dialog is bounded and fails instead of hanging'

write_sudo_stub 1 'exit 0'
if run_ladder "$scratch/behave-kde.sh" >/dev/null; then
  fail 'the ladder resolved with no terminal and no graphical session'
fi
pass 'with no terminal and no graphical session the ladder fails'

if run_ladder "$scratch/behave-none.sh" DISPLAY=:0 >/dev/null; then
  fail 'the none shape resolved through an askpass rung it must not have'
fi
pass 'the none shape fails without ever reaching a helper'

# The state every fresh desktop host is in before the package script has run:
# the helper is named but not installed.
chmod 000 "$scratch/bin/askpass-stub"
if run_ladder "$scratch/behave-kde.sh" DISPLAY=:0 >/dev/null; then
  fail 'the ladder resolved with a named but non-executable helper'
fi
chmod 700 "$scratch/bin/askpass-stub"
pass 'a named but non-executable helper does not resolve the ladder'

# A host with no sudo at all must reach the declared exit, not hand the script a
# SUDO array whose first privileged call dies with command not found. This needs
# the hermetic bin: hiding the stub while /usr/bin is still on PATH only exposes
# the real sudo, and on a runner with passwordless sudo that resolves rung 2.
#
# What this scenario does and does not prove: it pins the OUTCOME (a no-sudo host
# reaches the declared exit), not the `command -v sudo` gate itself. Without that
# gate the ladder still fails here, because the askpass rung's own `sudo -A -v`
# also fails when the binary is missing — verified by removing the gate. The gate
# is pinned by the render-half assertion above, which is what keeps the failure a
# declared exit rather than a `command not found` at the first privileged call.
ladder_path="$scratch/nosudo-bin"
if run_ladder "$scratch/behave-kde.sh" DISPLAY=:0 >/dev/null; then
  fail 'the ladder resolved on a host with no sudo binary'
fi
ladder_path="$scratch/bin:/usr/bin:/bin"
pass 'a host with no sudo binary reaches the declared exit'

printf 'sudo-elevation-guard: all elevation ladder gates passed\n'
