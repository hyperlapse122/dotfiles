#!/usr/bin/env bash
# Render/syntax/gate-string regression guard for the garden registry
# relocation (docs/plans/2026-07-30-002-refactor-relocate-garden-registry-plan.md,
# unit U5). Proves the registry moved from the old target `src/garden.yaml`
# to `~/.config/garden/garden.yaml` without breaking either consumer.
#
# CI has no GPG private key, so the encrypted registry content itself is
# never decrypted here (KTD10) — that verification is local-only. This script
# only renders templates, checks syntax, and greps gate strings:
#   1. reconcile render matrix (linux/darwin non-empty + bash -n, windows empty)
#   2. reconcile fingerprint names the new source path, not the old one
#   3. src-audit syntax (sh -n)
#   4. no --chdir left in either consumer
#   5. .chezmoiignore gate strings (default + windows-forced render; the
#      container fact is asserted statically — see Check 5 below)
#   6. the registry source ciphertext starts with the PGP armor header
#   7. the old target literal `src/garden.yaml` is gone repo-wide except the
#      two paths that must still name it
#   8. a rendered-reconcile smoke run against stub garden/aoe with ~/src
#      absent
#
# Modelled on .ci/test-open-design-integration.sh (scratch dir, empty chezmoi
# config, render() helper, trap cleanup, chezmoi apply NEVER runs, nothing is
# decrypted) and .ci/test-tmux-kitty-passthrough.sh (fail() shape). Takes the
# repo root as $1, like .ci/test-compound-engineering-overlays.sh, so it can
# be pointed at a scratch copy of the repo for its own self-test (each check
# reads only from $repo_root, never a hardcoded path).
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

# --- Check 4: no --chdir -----------------------------------------------------
if grep -q -- '--chdir' "$repo_root/$reconcile_tmpl"; then
  fail 'reconcile template still contains --chdir'
fi
if grep -q -- '--chdir' "$audit_src"; then
  fail 'src-audit still contains --chdir'
fi

# --- Check 5: ignore-list gate strings ---------------------------------------
[ -f "$ignore_file" ] || fail ".chezmoiignore missing at $ignore_file"

gate_count=$(grep -cF '.config/garden/garden.yaml' "$ignore_file" || true)
[ "$gate_count" -eq 2 ] \
  || fail "expected exactly 2 occurrences of '.config/garden/garden.yaml' in .chezmoiignore, found $gate_count"
if grep -qF 'src/garden.yaml' "$ignore_file"; then
  fail '.chezmoiignore still references the old target literal src/garden.yaml'
fi

ignore_windows_render="$scratch/chezmoiignore-windows"
render_os windows '.chezmoiignore' >"$ignore_windows_render"
grep -qF '.config/garden/garden.yaml' "$ignore_windows_render" \
  || fail 'windows-rendered .chezmoiignore is missing the new gate literal'

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

# --- Check 6: ciphertext armor -----------------------------------------------
asc="$repo_root/dot_config/garden/encrypted_readonly_garden.yaml.asc"
[ -f "$asc" ] || fail 'registry ciphertext source missing at dot_config/garden/encrypted_readonly_garden.yaml.asc'
armor_line=$(head -n1 "$asc")
[ "$armor_line" = '-----BEGIN PGP MESSAGE-----' ] \
  || fail "registry ciphertext does not start with the PGP armor header (got: $armor_line)"

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

call_log="$scratch/garden-calls.log"
: >"$call_log"

# Minimal stubs. `garden`: records every invocation, mimics the one behavior
# the smoke test depends on (`grow` creates the configured root, here
# $HOME/src, when it is absent), and answers `ls -v` with one plausible grown
# tree line so the rendered script's own completeness check has something
# real to verify. `cmd` (setup-gitdir/setup-upstream/aoe-session) is a no-op —
# exercising the real aoe bootstrap is out of scope (Risk-2: stubs cannot
# cover the real binaries' behavior). `aoe` is only probed with `command -v`.
cat >"$stub_bin/garden" <<STUB
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "\$*" >>"$call_log"
case " \$* " in
  *' grow '*)
    mkdir -p "\$HOME/src"
    ;;
  *' ls '*)
    printf '# demo main $demo_tree\n'
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

[ ! -d "$fake_home/src" ] || fail 'smoke test precondition violated: ~/src already exists before grow'

if ! PATH="$stub_bin:$PATH" HOME="$fake_home" bash "$linux_render"; then
  fail 'rendered linux reconcile script exited non-zero with ~/src absent'
fi

[ -d "$fake_home/src" ] || fail 'rendered reconcile did not create ~/src via garden grow'
grep -qF ' grow ' "$call_log" || fail 'stub garden never recorded a grow invocation'

printf 'garden registry relocation checks passed\n'
