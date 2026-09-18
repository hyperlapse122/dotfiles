#!/usr/bin/env bash
# Isolated, network-free ownership-model regression test with two applies (U2).
#
# Proves that an excluded target written by a run_after_ script, fed from an
# include-only pristine external, survives a second non-interactive apply (R3, R6, KTD2).
# Also proves the negative control: without the exclude, the second non-interactive apply
# aborts with "has changed since chezmoi last wrote it", proving that chezmoi's drift
# check sees outside writes and that only exclude removes the entryState conflict.
#
# Scenarios tested:
#   1. With exclude: first apply extracts archive (excluding overlay targets), extracts
#      pristine files, and runs run_after_ script to write customized target files.
#   2. The pristine files are byte-identical to the upstream archive members, their parent
#      directories exist, and executable bits match the archive.
#   3. An include pattern matching no archive member applies cleanly.
#   4. With exclude: second non-interactive apply exits 0 and written target files retain
#      the script's customized content.
#   5. Negative control: without exclude, the second non-interactive apply exits non-zero
#      and reports "has changed since chezmoi last wrote it".
#
set -euo pipefail

root="${1:-$(pwd)}"

# Resolve chezmoi executable
chezmoi_bin="$(command -v chezmoi || true)"
if [[ -z "$chezmoi_bin" || ! -x "$chezmoi_bin" ]]; then
  echo "test-ce-overlay-entrystate: chezmoi binary not found or not executable" >&2
  exit 1
fi

scratch_root="${RUNNER_TEMP:-${XDG_RUNTIME_DIR:-"$HOME/.cache"}}"
mkdir -p -- "$scratch_root"
scratch="$(mktemp -d "$scratch_root/ce-entrystate.XXXXXX")"
trap 'rm -rf -- "$scratch"' EXIT

bin="$scratch/bin"
mkdir -p -- "$bin"
printf '#!/usr/bin/env bash\ncase "${1-}" in whoami) printf dummy@example.invalid;; *) printf dummy-secret;; esac\n' > "$bin/op"
chmod 700 -- "$bin/op"

# Empty config file to isolate from any host chezmoi config
: > "$scratch/empty.toml"

# Isolated PATH: stub op directory + standard system directories only
safe_path="$bin:/usr/bin:/bin"

fixture_dir="$root/.ci/fixtures/ce-overlay-entrystate"
upstream_fixture="$fixture_dir/upstream"
source_fixture="$fixture_dir/source"

if [[ ! -d "$upstream_fixture" ]]; then
  echo "test-ce-overlay-entrystate: fixture upstream directory missing: $upstream_fixture" >&2
  exit 1
fi
if [[ ! -d "$source_fixture" ]]; then
  echo "test-ce-overlay-entrystate: fixture source directory missing: $source_fixture" >&2
  exit 1
fi

# Build tarball at test time from fixture upstream tree
tar_staging="$scratch/tar-staging/compound-engineering-v1.0.0"
mkdir -p -- "$tar_staging"
cp -a "$upstream_fixture/." "$tar_staging/"
tar_path="$scratch/ce-upstream.tar.gz"
tar -czf "$tar_path" -C "$scratch/tar-staging" "compound-engineering-v1.0.0"
tar_url="file://$tar_path"

# Helper to run a test scenario (with_exclude: true or false)
run_scenario() {
  local with_exclude="$1"
  local scenario_name="with-exclude"
  if [[ "$with_exclude" != "true" ]]; then
    scenario_name="no-exclude"
  fi

  local run_dir="$scratch/run-$scenario_name"
  local src="$run_dir/source"
  local dst="$run_dir/target-home"
  local state="$run_dir/state.boltdb"
  local cache="$run_dir/cache"
  mkdir -p -- "$run_dir" "$dst" "$cache"

  # Copy minimal fixture source state
  cp -a "$source_fixture/." "$src/"

  # Configure dynamic parameters for this scenario
  mkdir -p -- "$src/.chezmoidata"
  cat > "$src/.chezmoidata/vars.yaml" <<EOF
archive_url: "$tar_url"
with_exclude: $with_exclude
EOF

  # First apply: non-interactive with --force
  env HOME="$run_dir" PATH="$safe_path" "$chezmoi_bin" \
    --config "$scratch/empty.toml" \
    --source "$src" \
    --destination "$dst" \
    --cache "$cache" \
    --persistent-state "$state" \
    --no-tty \
    apply --force

  # Verify pristine extractions
  local p_interview="$dst/pristine/skills/ce-sweep/references/interview.md"
  local p_dispatch="$dst/pristine/skills/ce-plan/scripts/elevation-dispatch.sh"

  [[ -f "$p_interview" ]] || { echo "pristine interview.md missing" >&2; exit 1; }
  [[ -f "$p_dispatch" ]] || { echo "pristine elevation-dispatch.sh missing" >&2; exit 1; }

  # Parent directories exist and are plain directories
  [[ -d "$dst/pristine/skills/ce-sweep/references" ]] || { echo "pristine references dir missing" >&2; exit 1; }
  [[ -d "$dst/pristine/skills/ce-plan/scripts" ]] || { echo "pristine scripts dir missing" >&2; exit 1; }

  # Pristine files are byte-identical to upstream archive members
  cmp -s "$upstream_fixture/skills/ce-sweep/references/interview.md" "$p_interview" \
    || { echo "pristine interview.md differs from upstream archive" >&2; exit 1; }
  cmp -s "$upstream_fixture/skills/ce-plan/scripts/elevation-dispatch.sh" "$p_dispatch" \
    || { echo "pristine elevation-dispatch.sh differs from upstream archive" >&2; exit 1; }

  # Executable bits match the archive
  [[ -x "$p_dispatch" ]] || { echo "pristine elevation-dispatch.sh lost executable bit" >&2; exit 1; }
  [[ ! -x "$p_interview" ]] || { echo "pristine interview.md unexpectedly executable" >&2; exit 1; }

  # Verify written target files after first apply
  local t_interview="$dst/target/skills/ce-sweep/references/interview.md"
  local t_dispatch="$dst/target/skills/ce-plan/scripts/elevation-dispatch.sh"

  [[ -f "$t_interview" ]] || { echo "target interview.md missing after apply 1" >&2; exit 1; }
  [[ -f "$t_dispatch" ]] || { echo "target elevation-dispatch.sh missing after apply 1" >&2; exit 1; }
  grep -q "customized interview by overlay script" "$t_interview" \
    || { echo "target interview.md missing script customization after apply 1" >&2; exit 1; }
  grep -q "customized dispatch by overlay script" "$t_dispatch" \
    || { echo "target elevation-dispatch.sh missing script customization after apply 1" >&2; exit 1; }

  # Second apply: non-interactive, WITHOUT --force
  local apply2_out="$run_dir/apply2.out"
  local apply2_err="$run_dir/apply2.err"

  if [[ "$with_exclude" == "true" ]]; then
    if ! env HOME="$run_dir" PATH="$safe_path" "$chezmoi_bin" \
      --config "$scratch/empty.toml" \
      --source "$src" \
      --destination "$dst" \
      --cache "$cache" \
      --persistent-state "$state" \
      --no-tty \
      apply > "$apply2_out" 2> "$apply2_err"; then
      echo "test-ce-overlay-entrystate: second apply aborted with exclude in place (stop condition):" >&2
      cat "$apply2_err" >&2
      cat "$apply2_out" >&2
      exit 1
    fi

    # Target files retain the script customization after second apply
    grep -q "customized interview by overlay script" "$t_interview" \
      || { echo "target interview.md lost script customization after apply 2" >&2; exit 1; }
    grep -q "customized dispatch by overlay script" "$t_dispatch" \
      || { echo "target elevation-dispatch.sh lost script customization after apply 2" >&2; exit 1; }

    # Pristine files remain byte-identical after second apply
    cmp -s "$upstream_fixture/skills/ce-sweep/references/interview.md" "$p_interview" \
      || { echo "pristine interview.md modified during second apply" >&2; exit 1; }
    cmp -s "$upstream_fixture/skills/ce-plan/scripts/elevation-dispatch.sh" "$p_dispatch" \
      || { echo "pristine elevation-dispatch.sh modified during second apply" >&2; exit 1; }
  else
    # Negative control: second apply must fail with drift error
    if env HOME="$run_dir" PATH="$safe_path" "$chezmoi_bin" \
      --config "$scratch/empty.toml" \
      --source "$src" \
      --destination "$dst" \
      --cache "$cache" \
      --persistent-state "$state" \
      --no-tty \
      apply > "$apply2_out" 2> "$apply2_err"; then
      echo "test-ce-overlay-entrystate: negative control failed: second apply unexpectedly succeeded without exclude" >&2
      exit 1
    fi

    local combined_output
    combined_output="$(cat "$apply2_out" "$apply2_err")"
    if ! echo "$combined_output" | grep -q "has changed since chezmoi last wrote it"; then
      echo "test-ce-overlay-entrystate: negative control failed: expected 'has changed since chezmoi last wrote it' not found in output:" >&2
      echo "$combined_output" >&2
      exit 1
    fi
  fi
}

# Positive test: with exclude
run_scenario "true"

# Negative control: without exclude
run_scenario "false"

echo "ce-overlay-entrystate: ok"
