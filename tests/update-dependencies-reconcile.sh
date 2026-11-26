#!/usr/bin/env bash
# Updater and commit contracts, plus merged workflow execution against real Git remotes.
set -euo pipefail

workflow=${1:-}
gitignore=${2:-}
publisher=${3:-}
verifier=${4:-}
runner=${5:-}
flake_inputs=${6:-}
if [[ $# -lt 5 || $# -gt 6 || -z $workflow || ! -f $workflow || -z $gitignore || ! -f $gitignore ]]; then
  printf 'usage: %s WORKFLOW_FILE GITIGNORE_FILE PUBLISHER VERIFIER RUNNER [FLAKE_INPUTS]\n' "${0##*/}" >&2
  exit 2
fi
if [[ -z $flake_inputs ]]; then
  flake_inputs=$(cd "$(dirname "$workflow")/../.." && pwd -P)/scripts/flake-inputs
else
  flake_inputs=$(cd "$(dirname "$flake_inputs")" && pwd -P)/$(basename "$flake_inputs")
fi
[[ -f $flake_inputs ]] || { printf 'update-dependencies-reconcile: FAIL: missing %s\n' "$flake_inputs" >&2; exit 2; }

fail() { printf 'update-dependencies-reconcile: FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'update-dependencies-reconcile: ok - %s\n' "$*"; }

for tool in git jq yq; do
  command -v "$tool" >/dev/null || fail "$tool is required"
done
git_bin=$(command -v git)

fix_branch=update-dependencies-fix

wf_json=$(yq -o=json '.' "$workflow")
[[ $(jq '.jobs | length' <<<"$wf_json") == 2 ]] || fail "expected maintenance and watch jobs"
job=$(jq '.jobs["update-dependencies"] // empty' <<<"$wf_json")
[[ -n $job ]] || fail "missing update-dependencies job in $workflow"

step_by_name() {
  jq -e --arg n "$1" '.steps[] | select(.name == $n)' <<<"$job"
}

step_run() {
  step_by_name "$1" | jq -r '.run // empty'
}

scratch=$(mktemp -d "${TMPDIR:-/tmp}/update-dependencies-reconcile.XXXXXX")
trap 'rm -rf -- "$scratch"' EXIT

# setup_clone <name>: a bare origin with main and a clone of it seeded with
# the repository's real .gitignore and baseline pin files.
setup_clone() {
  local name=$1
  local origin=$scratch/$name-origin.git
  local clone=$scratch/$name-clone
  "$git_bin" init -q --bare "$origin"
  "$git_bin" -C "$origin" config init.defaultBranch main
  "$git_bin" --git-dir "$origin" symbolic-ref HEAD refs/heads/main
  "$git_bin" clone -q "$origin" "$clone"
  "$git_bin" -C "$clone" config user.email t@example.invalid
  "$git_bin" -C "$clone" config user.name Test
  "$git_bin" -C "$clone" checkout -qb main
  cp "$gitignore" "$clone/.gitignore"
  cat >"$clone/flake.nix" <<'EOF'
{
  # BEGIN flake-inputs (generated from flake-inputs.json; do not edit)
  # END flake-inputs
}
EOF
  cat >"$clone/flake-inputs.json" <<'EOF'
{
  "version": 1,
  "inputs": {
    "compound-engineering-plugin": {
      "repo": "github:EveryInc/compound-engineering-plugin",
      "ref": "compound-engineering-v2.67.0",
      "flake": false
    },
    "omp": {
      "repo": "github:can1357/oh-my-pi",
      "ref": "v19.1.1"
    }
  }
}
EOF
  python3 "$flake_inputs" generate --write --registry "$clone/flake-inputs.json" --flake "$clone/flake.nix" >/dev/null 2>&1 ||
    { echo "could not render the seeded flake.nix" >&2; exit 1; }
  cat >"$clone/flake.lock" <<'EOF'
{
  "nodes": {
    "compound-engineering-plugin": {
      "locked": {
        "rev": "1111111111111111111111111111111111111111"
      }
    },
    "omp": {
      "locked": {
        "rev": "3333333333333333333333333333333333333333"
      }
    }
  }
}
EOF
  mkdir -p "$clone/home/h82/agents" "$clone/packages/acpx"
  cat >"$clone/home/h82/agents/agent-plugin-pins.nix" <<'EOF'
{
  compound-engineering = {
    tag = "compound-engineering-v2.67.0";
    expectedRev = "1111111111111111111111111111111111111111";
  };
}
EOF
  printf '{"version": "1.0.0"}\n' >"$clone/packages/claude-desktop-version.json"
  printf '{"version": "1.0.0"}\n' >"$clone/packages/claude-code-manifest.json"
  printf '{"latest": {"cmdline-tools": "19.0"}}\n' >"$clone/packages/android-sdk-repo.json"
  printf '{"version": "2026.10.0"}\n' >"$clone/packages/mise-release.json"
  printf '{"version": "1.0.0"}\n' >"$clone/packages/ant-release.json"
  printf '{"tag": "v0.40.16"}\n' >"$clone/packages/ollama-release.json"
  printf '{"zshLock":{"archives":[{"commit":"1111111111111111111111111111111111111111"}]}}\n' >"$clone/packages/prezto-pin.json"
  printf '{"version": "0.0.45"}\n' >"$clone/packages/t3code-release.json"
  printf '{"version": "2.3.1", "platforms": {}}\n' >"$clone/packages/opencode-release.json"
  printf '{"version": "19.1.1", "rev": "3333333333333333333333333333333333333333", "platforms": {}}\n' >"$clone/packages/omp-release.json"
  printf '{"version": "1.4.0", "platforms": {}}\n' >"$clone/packages/pi-release.json"
  printf '{"version": "0.20.0"}\n' >"$clone/packages/acpx-release.json"
  printf '{"lockfileVersion": 3, "name": "acpx"}\n' >"$clone/packages/acpx/package-lock.json"
  printf 'base\n' >"$clone/tracked.txt"
  "$git_bin" -C "$clone" add -A
  "$git_bin" -C "$clone" commit -qm init
  "$git_bin" -C "$clone" push -q origin main
  printf '%s %s\n' "$origin" "$clone"
}

# --- Update step (full script execution) ------------------------------------

update_script=$(step_run 'Update flake inputs, agent plugins, and packages')
[[ -n $update_script ]] || fail "could not find the update step's run block in $workflow"

# run_update_step <name> [env-assignments...]: runs the full update step script
# against an argument-checking `nix` stub.
run_update_step() {
  local name=$1 origin clone status=0
  shift
  read -r origin clone <<<"$(setup_clone "$name")"
  mkdir -p "$scratch/$name-bin"
  cat >"$scratch/$name-bin/nix" <<EOF
#!$BASH
set -euo pipefail
printf '%s\n' "\$*" >>"$scratch/$name-nix.log"
case "\$*" in
  "flake update")
    exit 0
    ;;
  "run .#agent-plugin-release -- --source EveryInc/compound-engineering-plugin --tag-prefix compound-engineering-")
    printf '%s\n' "\${RESOLVED_TAG:-compound-engineering-v2.68.0}"
    ;;
  "flake lock --update-input compound-engineering-plugin")
    jq --arg rev "\${LOCKED_REV:-2222222222222222222222222222222222222222}" \
      '.nodes["compound-engineering-plugin"].locked.rev = \$rev' flake.lock >flake.lock.tmp
    mv flake.lock.tmp flake.lock
    ;;
  "run .#omp-release -- --output packages/omp-release.json")
    if [[ " \${FAIL_SOFT:-} " == *" omp "* ]]; then
      printf '{"version": "partial' >packages/omp-release.json
      echo "omp-release: release v19.2.0 lists 0 omp-linux-x64 assets" >&2
      exit 1
    fi
    if [[ \${OMP_UNCHANGED:-0} == 1 ]]; then exit 0; fi
    printf '{"version": "19.2.0", "rev": "4444444444444444444444444444444444444444", "platforms": {}}\n' >packages/omp-release.json
    ;;
  "flake lock --update-input omp")
    jq --arg rev "\${OMP_LOCKED_REV:-4444444444444444444444444444444444444444}" \
      '.nodes.omp.locked.rev = \$rev' flake.lock >flake.lock.tmp
    mv flake.lock.tmp flake.lock
    ;;
  "run .#claude-desktop-release -- --output packages/claude-desktop-version.json")
    printf '{"version": "1.1.0"}\n' >packages/claude-desktop-version.json
    ;;
  "run .#claude-code-release -- --output packages/claude-code-manifest.json")
    if [[ " \${FAIL_SOFT:-} " == *" claude-code "* ]]; then
      printf '{"version": "partial' >packages/claude-code-manifest.json
      echo "claude-code-release: manifest for 2.1.0 lacks linux-arm64" >&2
      exit 1
    fi
    printf '{"version": "2.1.0"}\n' >packages/claude-code-manifest.json
    ;;
  "run .#android-sdk-release -- --output packages/android-sdk-repo.json")
    printf '{"latest": {"cmdline-tools": "20.0", "platform-tools": "36.0.0"}}\n' >packages/android-sdk-repo.json
    ;;
  "run .#ant-release -- --output packages/ant-release.json")
    printf '{"version": "2.0.0"}\n' >packages/ant-release.json
    ;;
  "run .#mise-release -- --output packages/mise-release.json")
    printf '{"version": "2026.10.5"}\n' >packages/mise-release.json
    ;;
  "run .#prezto-release -- --output packages/prezto-pin.json")
    if [[ \${FAIL_PREZTO:-0} == 1 ]]; then exit 1; fi
    printf '{"zshLock":{"archives":[{"commit":"2222222222222222222222222222222222222222"}]}}\n' >packages/prezto-pin.json
    ;;
  "run .#t3code-release -- --output packages/t3code-release.json")
    if [[ " \${FAIL_SOFT:-} " == *" t3code "* ]]; then
      printf '{"version": "partial' >packages/t3code-release.json
      echo "t3code-release: release v0.0.47 lists 0 t3-0.0.47-linux-arm64.tar.gz assets" >&2
      exit 1
    fi
    printf '{"version": "0.0.47"}\n' >packages/t3code-release.json
    ;;
  "run .#opencode-release -- --output packages/opencode-release.json")
    if [[ " \${FAIL_SOFT:-} " == *" opencode "* ]]; then
      printf '{"version": "partial' >packages/opencode-release.json
      echo "opencode-release: release v2.3.3 lists 0 opencode-linux-x64.tar.gz assets" >&2
      exit 1
    fi
    printf '{"version": "2.3.2", "platforms": {}}\n' >packages/opencode-release.json
    ;;
  "run .#overlay-release -- --output packages/bun-pin.json"|"run .#overlay-release -- --output packages/overlay-fonts.json")
    echo "\$*" >>"$clone/overlay-calls.log"
    ;;
  "run .#overlay-release -- --output packages/ollama-release.json")
    if [[ " \${FAIL_SOFT:-} " == *" ollama "* ]]; then
      printf '{"tag": "partial' >packages/ollama-release.json
      echo "overlay-release: missing Ollama asset" >&2
      exit 1
    fi
    printf '{"tag": "v0.40.17"}\n' >packages/ollama-release.json
    ;;
  "run .#pi-release -- --output packages/pi-release.json")
    if [[ " \${FAIL_SOFT:-} " == *" pi "* ]]; then
      printf '{"version": "partial' >packages/pi-release.json
      echo "pi-release: release v1.5.0 has no pi-linux-arm64" >&2
      exit 1
    fi
    printf '{"version": "1.5.0", "platforms": {}}\n' >packages/pi-release.json
    ;;
  "run .#npm-release -- --package acpx --output packages/acpx-release.json --lock packages/acpx/package-lock.json")
    echo "acpx" >>"$clone/npm-calls.log"
    if [[ " \${FAIL_SOFT:-} " == *" acpx "* ]]; then
      printf '{"version": "partial' >packages/acpx-release.json
      printf 'partial' >packages/acpx/package-lock.json
      echo "npm-release: npm could not write a lock file" >&2
      exit 1
    fi
    printf '{"version": "9.9.9"}\n' >packages/acpx-release.json
    printf '{"lockfileVersion": 3, "name": "acpx", "new": true}\n' >packages/acpx/package-lock.json
    ;;
  "run .#flake-inputs -- set compound-engineering-plugin --ref compound-engineering-v2.68.0")
    python3 "$flake_inputs" set compound-engineering-plugin --ref compound-engineering-v2.68.0
    ;;
  "run .#flake-inputs -- set omp --ref v19.2.0")
    python3 "$flake_inputs" set omp --ref v19.2.0
    ;;
  "run .#flake-inputs -- generate --write")
    python3 "$flake_inputs" generate --write
    ;;
  *)
    echo "unexpected nix invocation: \$*" >&2
    exit 99
    ;;
esac
EOF
  chmod +x "$scratch/$name-bin/nix"
  : >"$scratch/$name-output"
  (
    cd "$clone"
    env "$@" PATH="$scratch/$name-bin:$PATH" GITHUB_OUTPUT="$scratch/$name-output" \
      bash -e -c "$update_script"
  ) >"$scratch/$name-step.log" 2>&1 || status=$?
  printf '%s %s\n' "$status" "$clone"
}

read -r status clone <<<"$(run_update_step update-all)"
((status == 0)) || fail "full update step failed: $(cat "$scratch/update-all-step.log")"
[[ $(jq -r '.zshLock.archives[0].commit' "$clone/packages/prezto-pin.json") == 2222222222222222222222222222222222222222 ]] ||
  fail 'update step did not refresh the Prezto pin'
grep -qx 'changed=true' "$scratch/update-all-output" ||
  fail "update step did not record changed=true: $(cat "$scratch/update-all-output")"
if grep -q '^::warning' "$scratch/update-all-step.log"; then
  fail "succeeding update step emitted a warning: $(cat "$scratch/update-all-step.log")"
fi
grep -q 'compound-engineering-plugin/compound-engineering-v2.68.0' "$clone/flake.nix" ||
  fail "update step did not update compound-engineering tag in flake.nix"
[[ $(jq -r '.inputs["compound-engineering-plugin"].ref' "$clone/flake-inputs.json") == compound-engineering-v2.68.0 ]] ||
  fail "update step did not update the compound-engineering registry ref"
[[ $(jq -r '.inputs.omp.ref' "$clone/flake-inputs.json") == v19.2.0 ]] ||
  fail "update step did not update the omp registry ref"
grep -q 'tag = "compound-engineering-v2.68.0";' "$clone/home/h82/agents/agent-plugin-pins.nix" ||
  fail "update step did not update tag in home/h82/agents/agent-plugin-pins.nix"
grep -q 'expectedRev = "2222222222222222222222222222222222222222";' "$clone/home/h82/agents/agent-plugin-pins.nix" ||
  fail "update step did not update expectedRev in home/h82/agents/agent-plugin-pins.nix"
grep -q '"2.1.0"' "$clone/packages/claude-code-manifest.json" ||
  fail "update step did not update packages/claude-code-manifest.json"
[[ $(jq -r .version "$clone/packages/ant-release.json") == 2.0.0 ]] || fail "ant updater did not run"
[[ $(jq -r .tag "$clone/packages/ollama-release.json") == v0.40.17 ]] || fail "Ollama updater did not run"
grep -q '0.0.47' "$clone/packages/t3code-release.json" ||
  fail "update step did not update packages/t3code-release.json"
grep -q '"2.3.2"' "$clone/packages/opencode-release.json" ||
  fail "update step did not update packages/opencode-release.json"
grep -q '"1.5.0"' "$clone/packages/pi-release.json" ||
  fail "update step did not update packages/pi-release.json"
grep -q '"9.9.9"' "$clone/packages/acpx-release.json" &&
  grep -q '"new": true' "$clone/packages/acpx/package-lock.json" ||
  fail "update step did not update acpx pin and lock file"
[[ $(paste -sd ' ' "$clone/npm-calls.log") == "acpx" ]] ||
  fail "npm-release did not run exactly once for acpx"
[[ $(wc -l <"$clone/overlay-calls.log") == 2 ]] || fail 'missing imported pin updater'
pass 'the update step runs flake update, compound-engineering-plugin pin/lock update, and all release updaters'

grep -q 'github:can1357/oh-my-pi/v19.2.0"' "$clone/flake.nix" ||
  fail "update step did not move the omp input to the new release tag: $(cat "$clone/flake.nix")"
[[ $(jq -r '.nodes.omp.locked.rev' "$clone/flake.lock") == 4444444444444444444444444444444444444444 ]] ||
  fail 'update step did not relock the omp input'
grep -qx 'flake lock --update-input omp' "$scratch/update-all-nix.log" ||
  fail 'update step did not relock only the omp input'
pass 'a new omp pin moves the flake tag and relocks the omp input'

read -r status clone <<<"$(run_update_step update-omp-unchanged OMP_UNCHANGED=1)"
((status == 0)) || fail "an unchanged omp pin aborted the update step: $(cat "$scratch/update-omp-unchanged-step.log")"
grep -q 'github:can1357/oh-my-pi/v19.1.1"' "$clone/flake.nix" ||
  fail 'an unchanged omp pin moved the flake tag'
if grep -qx 'flake lock --update-input omp' "$scratch/update-omp-unchanged-nix.log"; then
  fail 'an unchanged omp pin relocked the omp input'
fi
pass 'an unchanged omp pin leaves the flake tag and lock alone'

read -r status clone <<<"$(run_update_step update-omp-soft-fail FAIL_SOFT=omp)"
((status == 0)) || fail "a failing omp release aborted the update step: $(cat "$scratch/update-omp-soft-fail-step.log")"
grep -q '^::warning title=omp update skipped::' "$scratch/update-omp-soft-fail-step.log" ||
  fail "missing omp warning: $(cat "$scratch/update-omp-soft-fail-step.log")"
[[ -z $("$git_bin" -C "$clone" status --porcelain packages/omp-release.json) ]] ||
  fail 'a failing omp release left a partial pin'
grep -q 'github:can1357/oh-my-pi/v19.1.1"' "$clone/flake.nix" ||
  fail 'a failing omp release moved the flake tag'
if grep -qx 'flake lock --update-input omp' "$scratch/update-omp-soft-fail-nix.log"; then
  fail 'a failing omp release relocked the omp input'
fi
pass 'a failing omp release warns, restores its pin, and leaves the flake tag alone'

read -r status _ <<<"$(run_update_step update-omp-rev-mismatch OMP_LOCKED_REV=5555555555555555555555555555555555555555)"
((status != 0)) || fail 'update step accepted an omp lock that differs from the pinned revision'
grep -q 'the omp input locked 5555555555555555555555555555555555555555, but packages/omp-release.json pins 4444444444444444444444444444444444444444' \
  "$scratch/update-omp-rev-mismatch-step.log" ||
  fail "update step did not name both omp revisions: $(cat "$scratch/update-omp-rev-mismatch-step.log")"
pass 'the update step stops when the omp lock differs from the pinned revision'

read -r status clone <<<"$(run_update_step update-soft-fail "FAIL_SOFT=t3code opencode pi acpx ollama")"
((status == 0)) || fail "soft-failing updaters aborted the update step: $(cat "$scratch/update-soft-fail-step.log")"
for title in "T3 Code update skipped" "OpenCode update skipped" "Pi update skipped" "acpx update skipped" "Ollama update skipped"; do
  grep -q "^::warning title=$title::" "$scratch/update-soft-fail-step.log" ||
    fail "missing warning for '$title': $(cat "$scratch/update-soft-fail-step.log")"
done
grep -q '^::warning title=T3 Code update skipped::.*lists 0 t3-0.0.47-linux-arm64.tar.gz assets' "$scratch/update-soft-fail-step.log" ||
  fail "the T3 Code warning does not carry the updater's message: $(cat "$scratch/update-soft-fail-step.log")"
[[ -z $("$git_bin" -C "$clone" status --porcelain \
  packages/t3code-release.json \
  packages/opencode-release.json \
  packages/ollama-release.json \
  packages/pi-release.json \
  packages/acpx-release.json \
  packages/acpx/package-lock.json) ]] ||
  fail "soft-failing updaters left partial changes in their pin or lock files"
pass 'soft-failing updaters (t3code, opencode, pi, acpx, ollama) warn, restore their files, and let the step continue'

read -r status clone <<<"$(run_update_step update-claude-code-failure "FAIL_SOFT=claude-code")"
((status == 0)) || fail "a failing Claude Code release aborted the update step"
grep -q '^::warning title=Claude Code update skipped::.*manifest for 2.1.0 lacks linux-arm64' "$scratch/update-claude-code-failure-step.log" ||
  fail "the Claude Code warning omitted the release error"
[[ -z $("$git_bin" -C "$clone" status --porcelain packages/claude-code-manifest.json) ]] ||
  fail "a failing Claude Code release left a partial pin"
grep -q '"1.5.0"' "$clone/packages/pi-release.json" ||
  fail "a failing Claude Code release stopped the Pi update"
pass 'a failing Claude Code release warns, restores the manifest, and lets later updates continue'

read -r status _ <<<"$(run_update_step update-bad-rev "LOCKED_REV=null")"
((status != 0)) || fail "update step accepted a non-hex locked revision for compound-engineering-plugin"
grep -q 'flake.lock recorded no usable revision' "$scratch/update-bad-rev-step.log" ||
  fail "update step did not report unusable flake.lock revision: $(cat "$scratch/update-bad-rev-step.log")"
pass 'the update step rejects an unusable locked revision for compound-engineering-plugin'

read -r status clone <<<"$(run_update_step prezto-failure FAIL_PREZTO=1)"
((status != 0)) || fail 'a failed Prezto refresh did not stop the update step'
[[ $(jq -r '.zshLock.archives[0].commit' "$clone/packages/prezto-pin.json") == 1111111111111111111111111111111111111111 ]] ||
  fail 'a failed Prezto refresh changed the pin'
pass 'a failed Prezto refresh stops publication and preserves its pin'

# --- Per-pin commit boundaries ---------------------------------------------

push_step=$(step_by_name 'Commit dependency candidates') ||
  fail "could not find the push step in $workflow"
push_script=$(jq -r '.run // empty' <<<"$push_step")
[[ -n $push_script ]] || fail "could not find the push step's run block in $workflow"

read -r origin clone <<<"$(setup_clone pin-bumps)"
base_sha=$("$git_bin" -C "$clone" rev-parse HEAD)
new_t3_version=0.0.46
printf '{"version": "2.0.0"}\n' >"$clone/packages/ant-release.json"
printf '{"tag": "v0.40.17"}\n' >"$clone/packages/ollama-release.json"
printf '{"zshLock":{"archives":[{"commit":"2222222222222222222222222222222222222222"}]}}\n' >"$clone/packages/prezto-pin.json"
printf '{"version": "%s"}\n' "$new_t3_version" >"$clone/packages/t3code-release.json"
printf '{"version": "1.5.0", "platforms": {}}\n' >"$clone/packages/pi-release.json"
printf '{"version": "0.21.0"}\n' >"$clone/packages/acpx-release.json"
printf '{"version": "2.3.2", "platforms": {}}\n' >"$clone/packages/opencode-release.json"
printf '{"version": "2.1.0"}\n' >"$clone/packages/claude-code-manifest.json"
printf '{"lockfileVersion": 3, "name": "acpx", "new": true}\n' >"$clone/packages/acpx/package-lock.json"
sed -i 's/compound-engineering-v2.67.0/compound-engineering-v2.68.0/' \
  "$clone/flake.nix" "$clone/flake-inputs.json" "$clone/home/h82/agents/agent-plugin-pins.nix"
sed -i 's/1111111111111111111111111111111111111111/2222222222222222222222222222222222222222/' \
  "$clone/flake.lock" "$clone/home/h82/agents/agent-plugin-pins.nix"
(cd "$clone" && bash -e -c "$push_script") >"$scratch/pin-bumps-step.log" 2>&1 ||
  fail "the push step failed on the per-pin updates: $(tail -n 5 "$scratch/pin-bumps-step.log")"
commits=$("$git_bin" -C "$clone" log --reverse --format='%H %s' "$base_sha..HEAD")
[[ $(wc -l <<<"$commits") == 9 ]] || fail "expected 9 per-pin commits, found: $commits"
for expected in \
  'chore(packages): bump ant to 2.0.0|packages/ant-release.json' \
  'chore(packages): refresh ollama-release|packages/ollama-release.json' \
  'chore(packages): refresh prezto to 222222222222|packages/prezto-pin.json' \
  'chore(packages): bump pi to 1.5.0|packages/pi-release.json' \
  'chore(packages): bump claude-code to 2.1.0|packages/claude-code-manifest.json' \
  'chore(packages): bump acpx to 0.21.0|packages/acpx-release.json packages/acpx/package-lock.json' \
  "chore(packages): bump t3code to $new_t3_version|packages/t3code-release.json" \
  'chore(packages): bump opencode to 2.3.2|packages/opencode-release.json' \
  'chore(agents): bump compound-engineering to compound-engineering-v2.68.0|flake-inputs.json flake.lock flake.nix home/h82/agents/agent-plugin-pins.nix'; do
  subject=${expected%%|*} want=${expected#*|}
  sha=$(awk -v s="$subject" '{ sha = $1; sub(/^[^ ]+ /, "") } $0 == s { print sha }' <<<"$commits")
  [[ -n $sha ]] || fail "no commit '$subject' among: $commits"
  files=$("$git_bin" -C "$clone" show --format= --name-only "$sha" | sort | paste -sd ' ')
  [[ $files == "$want" ]] || fail "'$subject' carries $files, want $want"
done
pass 'the Prezto, claude-code, t3code, opencode, ollama, pi, acpx, and compound-engineering changes each land as their own commit with only their files'
read -r origin clone <<<"$(setup_clone omp-bump)"
base_sha=$("$git_bin" -C "$clone" rev-parse HEAD)
printf '{"version": "19.2.0", "rev": "4444444444444444444444444444444444444444", "platforms": {}}\n' >"$clone/packages/omp-release.json"
sed -i 's#oh-my-pi/v19.1.1#oh-my-pi/v19.2.0#' "$clone/flake.nix"
sed -i 's#"ref": "v19.1.1"#"ref": "v19.2.0"#' "$clone/flake-inputs.json"
sed -i 's/3333333333333333333333333333333333333333/4444444444444444444444444444444444444444/' "$clone/flake.lock"
(cd "$clone" && bash -e -c "$push_script") >"$scratch/omp-bump-step.log" 2>&1 ||
  fail "the push step failed on the omp update: $(tail -n 5 "$scratch/omp-bump-step.log")"
commits=$("$git_bin" -C "$clone" log --format='%H %s' "$base_sha..HEAD")
[[ $(wc -l <<<"$commits") == 1 && $commits == *' chore(packages): bump omp to 19.2.0' ]] ||
  fail "expected one omp bump commit, found: $commits"
files=$("$git_bin" -C "$clone" show --format= --name-only HEAD | sort | paste -sd ' ')
[[ $files == 'flake-inputs.json flake.lock flake.nix packages/omp-release.json' ]] ||
  fail "the omp bump carries $files, want flake-inputs.json flake.lock flake.nix packages/omp-release.json"
pass 'an omp update lands as one commit carrying its pin, the flake tag, and the lock'

python3 "$runner" "$workflow" "$publisher" "$verifier"
