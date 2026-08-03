#!/usr/bin/env bash
# Render/syntax/gate-string regression guard for the garden registry
# relocation (docs/plans/2026-07-30-002-refactor-relocate-garden-registry-plan.md,
# unit U5). Proves the registry moved from the old target `src/garden.yaml`
# to `~/.config/garden/garden.yaml` without breaking either consumer.
#
# CI has no GPG private key, so the encrypted registry content itself is
# never decrypted here (KTD10) — that verification is local-only. This script
# only renders templates, checks syntax, greps gate strings, and runs both
# consumers against stubs:
#   1. reconcile render matrix (linux/darwin non-empty + bash -n, windows empty)
#   2. reconcile fingerprint names the new source path, not the old one
#   3. src-audit syntax (sh -n) — Check 11 below actually executes it
#   4. no --chdir left in either consumer, and --config "$reg" reaches all
#      three garden invocations in each (static; Checks 8-10 confirm the
#      same dynamically, from the stub's recorded argv)
#   5. .chezmoiignore gate strings (default + windows-forced render; the
#      container fact is asserted statically — see Check 5 below)
#   6. the registry source ciphertext starts with the PGP armor header AND
#      its gpg packet structure actually holds a pubkey-enc packet and an
#      encrypted-data packet — the armor header alone proves nothing
#   7. the old target literal `src/garden.yaml` is gone repo-wide except the
#      two paths that must still name it, and .chezmoiremove still carries
#      its prune entry for the old target
#   8. a rendered-reconcile smoke run against stub garden/aoe with ~/src
#      absent (happy path; also asserts --config reached the stub's argv)
#   9. rendered-reconcile smoke: registry absent -> non-zero, names the path
#  10. rendered-reconcile smoke: half-grown/broken tree -> non-zero, names it
#  11. src-audit actually runs (~/src absent -> exit 0 + its message), and
#      its reg= line still literally assigns the new path
set -euo pipefail

repo_root="${1:-$(git rev-parse --show-toplevel)}"

scratch_root=${RUNNER_TEMP:-${XDG_RUNTIME_DIR:-"$HOME/.cache"}}
mkdir -p -- "$scratch_root"
scratch=$(mktemp -d "$scratch_root/garden-registry-relocation.XXXXXX")
trap 'rm -rf -- "$scratch"' EXIT

fail() {
  printf 'garden-registry-relocation: %s\n' "$1" >&2
  exit 1
}

command -v chezmoi >/dev/null 2>&1 || fail 'chezmoi is required'
command -v git >/dev/null 2>&1 || fail 'git is required'

empty_config="$scratch/empty.toml"
target="$scratch/target"
: >"$empty_config"
mkdir -p "$target"

reconcile_tmpl='.chezmoiscripts/90-src/run_onchange_after_reconcile-garden.sh.tmpl'
audit_src="$repo_root/dot_local/bin/executable_src-audit"
ignore_file="$repo_root/.chezmoiignore"

# render_os <os> <repo-relative-template-path> — renders with an empty config
# (so the real .chezmoi.toml.tmpl is never read) and a throwaway destination.
render_os() {
  chezmoi --config "$empty_config" --source "$repo_root" \
    --destination "$target" --override-data "{\"chezmoi\":{\"os\":\"$1\"}}" \
    execute-template <"$repo_root/$2"
}

# --- Check 1: reconcile render matrix ---------------------------------------
# linux/darwin are the two hosts the ~/src garden runs on; windows renders
# empty via the template's own OS guard. A container render is deliberately
# NOT expected empty here — the container skip lives in .chezmoiignore, not
# in this template's guard (see Check 5).
linux_render="$scratch/reconcile-linux.sh"
darwin_render="$scratch/reconcile-darwin.sh"
windows_render="$scratch/reconcile-windows.sh"
render_os linux "$reconcile_tmpl" >"$linux_render"
render_os darwin "$reconcile_tmpl" >"$darwin_render"
render_os windows "$reconcile_tmpl" >"$windows_render"

[ -s "$linux_render" ] || fail 'reconcile template rendered empty for linux'
[ -s "$darwin_render" ] || fail 'reconcile template rendered empty for darwin'
bash -n "$linux_render" || fail 'linux reconcile render failed bash -n'
bash -n "$darwin_render" || fail 'darwin reconcile render failed bash -n'
[ ! -s "$windows_render" ] || fail 'reconcile template expected an empty render for windows'

# --- Check 2: fingerprint path -----------------------------------------------
grep -qF 'dot_config/garden/encrypted_readonly_garden.yaml.asc' "$linux_render" \
  || fail 'linux reconcile fingerprint is missing the new source path dot_config/garden/encrypted_readonly_garden.yaml.asc'
if grep -qF 'src/encrypted_readonly_garden.yaml.asc' "$linux_render"; then
  fail 'linux reconcile fingerprint still names the old source path src/encrypted_readonly_garden.yaml.asc'
fi

# --- Check 3: audit syntax ---------------------------------------------------
sh -n "$audit_src" || fail 'dot_local/bin/executable_src-audit failed sh -n'

# --- Check 4: no --chdir, and --config "$reg" reaches every garden call -----
if grep -q -- '--chdir' "$repo_root/$reconcile_tmpl"; then
  fail 'reconcile template still contains --chdir'
fi
if grep -q -- '--chdir' "$audit_src"; then
  fail 'src-audit still contains --chdir'
fi

# Static: each file's three garden invocations must each pass --config
# "$reg" — a dropped call site (falling back to ambient discovery) is a
# silent regression that forbidding --chdir alone would not catch. Checks
# 8-10 below assert the same thing dynamically from the stub's recorded argv.
reconcile_config_count=$(grep -cF -- '--config "$reg"' "$repo_root/$reconcile_tmpl" || true)
[ "$reconcile_config_count" -eq 3 ] \
  || fail "expected exactly 3 occurrences of --config \"\$reg\" in $reconcile_tmpl (one per garden invocation), found $reconcile_config_count"
audit_config_count=$(grep -cF -- '--config "$reg"' "$audit_src" || true)
[ "$audit_config_count" -eq 3 ] \
  || fail "expected exactly 3 occurrences of --config \"\$reg\" in dot_local/bin/executable_src-audit (one per garden invocation), found $audit_config_count"

# --- Check 5: ignore-list gate strings ---------------------------------------
[ -f "$ignore_file" ] || fail ".chezmoiignore missing at $ignore_file"

gate_count=$(grep -cF '.config/garden/garden.yaml' "$ignore_file" || true)
[ "$gate_count" -eq 1 ] \
  || fail "expected only the container gate for '.config/garden/garden.yaml' in .chezmoiignore, found $gate_count"
if grep -qF 'src/garden.yaml' "$ignore_file"; then
  fail '.chezmoiignore still references the old target literal src/garden.yaml'
fi

ignore_windows_render="$scratch/chezmoiignore-windows"
render_os windows '.chezmoiignore' >"$ignore_windows_render"
if grep -qF '.config/garden/garden.yaml' "$ignore_windows_render"; then
  fail 'windows-rendered .chezmoiignore still withholds the garden registry'
fi

# The container fact is a live `stat /run/.containerenv` / `stat /.dockerenv`
# probe in .chezmoitemplates/facts.tmpl, not a `.chezmoi.*` builtin — it is
# never read from template data, so `--override-data` cannot force it (probed
# directly: `--override-data '{"chezmoi":{"container":true}}'` and the
# top-level `{"container":true}` form both leave the container block
# unrendered here). Asserting it live would mean touching real container
# marker files, which an unprivileged self-test copy cannot do portably. So:
# assert the container block statically — the new literal must sit inside the
# `{{- if $f.container }}` block alongside the 90-src script glob it is meant
# to travel with.
container_start=$(grep -nF '{{- if $f.container }}' "$ignore_file" | head -n1 | cut -d: -f1 || true)
[ -n "$container_start" ] || fail 'container-fact block start not found in .chezmoiignore'
container_end_rel=$(tail -n "+$container_start" "$ignore_file" | grep -nF '{{- end }}' | head -n1 | cut -d: -f1 || true)
[ -n "$container_end_rel" ] || fail 'container-fact block end not found in .chezmoiignore'
container_end=$((container_start + container_end_rel - 1))
container_block=$(sed -n "${container_start},${container_end}p" "$ignore_file")
printf '%s\n' "$container_block" | grep -qF '.config/garden/garden.yaml' \
  || fail 'container-fact block in .chezmoiignore is missing the new gate literal'
printf '%s\n' "$container_block" | grep -qF '.chezmoiscripts/90-src/*.sh' \
  || fail 'container-fact block in .chezmoiignore is missing the 90-src script glob'

# --- Check 6: ciphertext is actually encrypted, not just armor-labeled ------
asc="$repo_root/dot_config/garden/encrypted_readonly_garden.yaml.asc"
[ -f "$asc" ] || fail 'registry ciphertext source missing at dot_config/garden/encrypted_readonly_garden.yaml.asc'
armor_line=$(head -n1 "$asc")
[ "$armor_line" = '-----BEGIN PGP MESSAGE-----' ] \
  || fail "registry ciphertext does not start with the PGP armor header (got: $armor_line)"

# The armor line alone is just a text marker a PLAINTEXT file could carry —
# it proves nothing about the content actually being encrypted. Parse the
# packet structure instead (needs no private key) and require both an
# encrypted-session-key packet and an encrypted-data packet. CI has gpg; a
# missing gpg fails loudly rather than silently skipping this check.
command -v gpg >/dev/null 2>&1 || fail 'gpg is required to verify the registry ciphertext packet structure'
# Do NOT gate on gpg's exit status. `--list-packets` also attempts decryption,
# so on any host without the private key (every CI runner) it prints the packet
# dump and THEN exits non-zero with "No secret key". The packet structure is the
# signal; the exit code is not. A file that is not PGP data emits no packet
# lines at all, so the two greps below still fail closed for plaintext.
packet_dump=$(gpg --list-packets --batch -- "$asc" 2>&1 || true)
printf '%s\n' "$packet_dump" | grep -qF 'pubkey enc packet' \
  || fail "registry ciphertext at $asc has no pubkey-enc packet — the armor header alone is not proof of encryption"
printf '%s\n' "$packet_dump" | grep -qF 'encrypted data packet' \
  || fail "registry ciphertext at $asc has no encrypted-data packet — the armor header alone is not proof of encryption"

# --- Check 7: stale literal sweep --------------------------------------------
# `.chezmoiremove`'s occurrence is the prune entry for the OLD deployed target
# (relative path `src/garden.yaml`, pruned during target application) plus its
# explanatory comment — it MUST keep naming that exact path forever, or a host
# that already deployed the old target never gets it pruned. `docs/` holds
# plan prose that quotes the old path deliberately, describing the world
# before this relocation. Both are legitimate holdouts, not regressions. This
# script's own basename is also excluded — it necessarily names the literal
# it is checking for.
stale_hits=$(grep -rlF 'src/garden.yaml' "$repo_root" \
  --exclude-dir=.git \
  --exclude-dir=docs \
  --exclude='.chezmoiremove' \
  --exclude='test-garden-registry-relocation.sh' \
  2>/dev/null || true)
if [ -n "$stale_hits" ]; then
  fail "old target literal 'src/garden.yaml' found outside .chezmoiremove/docs: $(printf '%s' "$stale_hits" | tr '\n' ' ')"
fi

# The sweep above excludes .chezmoiremove because ITS occurrence is the
# prune instruction for the OLD deployed target — legitimate, and required
# forever. But excluding it means nothing proves that entry still exists:
# deleting it would keep this sweep green while upgraded hosts keep a stale
# deployed ~/src/garden.yaml forever. Assert the prune entry line itself is
# present. It now sits inside a template conditional (non-Windows,
# non-container gating) — match the bare entry text, not the guard.
remove_file="$repo_root/.chezmoiremove"
[ -f "$remove_file" ] || fail ".chezmoiremove missing at $remove_file"
grep -qxF 'src/garden.yaml' "$remove_file" \
  || fail '.chezmoiremove is missing its src/garden.yaml prune entry for the old deployed target'

# --- Check 8: rendered-reconcile smoke with ~/src absent ---------------------
stub_bin="$scratch/stubbin"
mkdir -p "$stub_bin"

fake_home="$scratch/fake-home"
mkdir -p "$fake_home/.config/garden"
printf 'trees: []\n' >"$fake_home/.config/garden/garden.yaml"

# A real (but empty) git work tree, so the stub's `ls` line exercises the
# rendered script's actual completeness check (git -C "$tp" rev-parse
# --is-inside-work-tree) rather than an empty tree list that would pass it
# vacuously.
demo_tree="$scratch/demo-tree"
git init -q "$demo_tree"

# A plain directory that is deliberately NOT a git repo, for the
# half-grown/broken-tree smoke test (F5b, Check 10) — STUB_MODE=broken
# points the stub's `ls` line at this instead of $demo_tree.
broken_tree="$scratch/broken-tree"
mkdir -p "$broken_tree"

call_log="$scratch/garden-calls.log"
: >"$call_log"

# Minimal stubs. `garden`: records every invocation (so callers can assert
# what flags actually reached it — see the --config checks below), mimics
# the one behavior the smoke test depends on (`grow` creates the configured
# root, here $HOME/src, when it is absent), and answers `ls -v` with one
# plausible tree line so the rendered script's own completeness check has
# something real to verify. STUB_MODE=broken swaps that line's path from
# the real (empty but valid) $demo_tree git work tree to $broken_tree, a
# plain directory that is deliberately NOT a git repo, to exercise the
# half-grown/broken-tree failure path (F5b) without touching the
# happy-path default. `cmd` (setup-gitdir/setup-upstream/aoe-session) is a
# no-op — exercising the real aoe bootstrap is out of scope (Risk-2: stubs
# cannot cover the real binaries' behavior). `aoe` is only probed with
# `command -v`.
cat >"$stub_bin/garden" <<STUB
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "\$*" >>"$call_log"
case " \$* " in
  *' grow '*)
    mkdir -p "\$HOME/src"
    ;;
  *' ls '*)
    if [ "\${STUB_MODE:-}" = broken ]; then
      printf '# demo main $broken_tree\n'
    else
      printf '# demo main $demo_tree\n'
    fi
    ;;
  *' cmd '*)
    :
    ;;
esac
STUB
chmod +x "$stub_bin/garden"

cat >"$stub_bin/aoe" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$stub_bin/aoe"

# (scratch home was just created above; ~/src cannot exist yet here)

if ! PATH="$stub_bin:$PATH" HOME="$fake_home" bash "$linux_render"; then
  fail 'rendered linux reconcile script exited non-zero with ~/src absent'
fi

[ -d "$fake_home/src" ] || fail 'rendered reconcile did not create ~/src via garden grow'
grep -qF ' grow ' "$call_log" || fail 'stub garden never recorded a grow invocation'
grep -qF -- "--config $fake_home/.config/garden/garden.yaml grow" "$call_log" \
  || fail "stub garden call log missing --config $fake_home/.config/garden/garden.yaml on the grow invocation (dropped or misdirected --config?)"
grep -qF -- "--config $fake_home/.config/garden/garden.yaml ls" "$call_log" \
  || fail "stub garden call log missing --config $fake_home/.config/garden/garden.yaml on the ls invocation (dropped or misdirected --config?)"

# --- Check 9: rendered-reconcile smoke — registry absent (F5a) --------------
# The reconcile template's own missing-registry guard (`[ -f "$reg" ] ||
# ...`) never executes in Check 8 above, since fake_home always has the
# registry. Prove the failure path: a scratch home with no
# .config/garden/garden.yaml must fail non-zero and name the registry path.
absent_reg_home="$scratch/fake-home-registry-absent"
mkdir -p "$absent_reg_home"
absent_reg_out="$scratch/registry-absent.out"
if PATH="$stub_bin:$PATH" HOME="$absent_reg_home" bash "$linux_render" >"$absent_reg_out" 2>&1; then
  fail 'rendered linux reconcile script exited 0 with the registry missing — expected the missing-registry precondition to fail it'
fi
grep -qF "$absent_reg_home/.config/garden/garden.yaml" "$absent_reg_out" \
  || fail "rendered linux reconcile registry-absent failure did not name the registry path (output: $(cat "$absent_reg_out"))"

# --- Check 10: rendered-reconcile smoke — half-grown/broken tree (F5b) ------
# check_tree's failure branches never execute in Check 8 either, since
# demo_tree there is a real, valid git work tree. STUB_MODE=broken repoints
# the stub's `ls` line at $broken_tree, a plain directory that is
# deliberately not a git repo, so garden reports it grown but the
# completeness check must classify it broken.
broken_home="$scratch/fake-home-broken-tree"
mkdir -p "$broken_home/.config/garden"
printf 'trees: []\n' >"$broken_home/.config/garden/garden.yaml"
broken_tree_out="$scratch/broken-tree.out"
if STUB_MODE=broken PATH="$stub_bin:$PATH" HOME="$broken_home" bash "$linux_render" >"$broken_tree_out" 2>&1; then
  fail 'rendered linux reconcile script exited 0 with a half-grown/broken tree present — expected the completeness check to fail it'
fi
grep -qF "$broken_tree" "$broken_tree_out" \
  || fail "rendered linux reconcile broken-tree failure did not name the broken tree (output: $(cat "$broken_tree_out"))"

# --- Check 11: src-audit actually runs, not just sh -n'd (F4) ----------------
# Check 3 above only proves the script parses. The plan's Verification
# Contract also assigns CI the ~/src-absent early-exit proof — run it.
audit_home="$scratch/audit-home"
mkdir -p "$audit_home"
audit_rc=0
audit_out=$(PATH="$stub_bin:$PATH" HOME="$audit_home" sh "$audit_src" 2>&1) || audit_rc=$?
[ "$audit_rc" -eq 0 ] \
  || fail "src-audit exited $audit_rc with \$HOME/src absent (expected 0 + early exit); output: $audit_out"
printf '%s\n' "$audit_out" | grep -qF 'nothing to audit' \
  || fail "src-audit did not print its 'nothing to audit' early-exit message with \$HOME/src absent; output: $audit_out"

# The stale-literal sweep (Check 7) cannot catch a reverted reg= line here:
# src-audit's OLD form referenced $src/garden.yaml via variable
# interpolation, not the literal text src/garden.yaml. Assert the
# assignment itself.
grep -qF 'reg="$HOME/.config/garden/garden.yaml"' "$audit_src" \
  || fail 'src-audit reg= line no longer literally assigns $HOME/.config/garden/garden.yaml (reverted to the old $src-relative form?)'

printf 'garden registry relocation checks passed\n'
