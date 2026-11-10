#!/usr/bin/env bash
#
# Check interface:
#
#   bash tests/check-workflow-docs-skip.sh <check.yml>
#
# Asserts the docs-only CI skip wiring in .github/workflows/check.yml:
#
# - flake-check, hosts, and build each depend on `changes` and declare an
#   `if:` that runs them on any non-pull_request event, or when the changes
#   job did not complete successfully, and skips only a definitive
#   docs_only:true (KTD4/R6/R7 in the docs-skip-markdown-lint plan).
#   flake-check and hosts declare exactly `needs: changes`; build also
#   needs hosts, so it may list `changes` among others (KTD9 in the
#   host-generic composition plan).
# - build reads its matrix from the hosts job's output, so the workflow
#   never lists host names (R19). build-linux does the same for the
#   non-NixOS outputs and aarch64 fixture checks, and sends aarch64 targets
#   to the ubuntu-24.04-arm runner so nothing is built under emulation.
#   build-darwin does the same for macOS outputs and checks, on macos-15.
# - check-shard-names and check-shards carry the same gate, so every flake
#   check still builds on every non-docs-only PR and on push now that
#   flake-check only evaluates. check-shards reads its matrix from
#   check-shard-names, so a check added to `checks` joins CI without a
#   workflow edit. Both listers fail on an empty name list.
# - vm-check-names and vm-checks carry the same gate, so the NixOS VM tests
#   that live outside `nix flake check` still run on every non-docs-only
#   PR and on push. vm-checks reads its matrix from vm-check-names, so a
#   VM test added to tests/vm-checks.nix joins CI without a workflow edit.
# - markdown-lint declares the complementary condition: it runs only on
#   a genuine docs_only:true PR, the one case no check-shards entry
#   already builds it, so it is exercised exactly once per event instead
#   of twice on ordinary PRs and push.
# - fmt carries no such conditional -- it always runs.
#
# Each assertion fails inside an explicit if/exit branch, never a
# negated `! grep`, per this repository's decorative-assertion
# learning (mutation-testing-reveals-decorative-nix-check-assertions.md):
# a `! grep` is exempt from `set -e` and would prove nothing.
#
# Every assertion feeds its input through a here-string, never
# `printf ... | grep -q`: grep -q exits at its first match, the printf
# still writing later lines then fails with a broken pipe, and pipefail
# reports that as a miss.

set -euo pipefail

file=${1:-}
if [ "$#" -ne 1 ] || [ -z "$file" ] || [ ! -r "$file" ]; then
  printf 'usage: %s CHECK_YML\n' "${0##*/}" >&2
  exit 2
fi

fail() {
  echo "$1" >&2
  exit 1
}

# job_block <name> <file>: the job's own lines (two-space job key through
# the line before the next two-space job key, or EOF), so a job's `if:`
# is never mistaken for a step's `if:` sitting deeper in the file.
job_block() {
  local job=$1 file=$2
  awk -v job="$job" '
    /^jobs:/ { in_jobs = 1; next }
    in_jobs && /^[^[:space:]]/ { in_jobs = 0; printing = 0 }
    in_jobs && /^  [A-Za-z0-9_-]+:[[:space:]]*(#.*)?$/ {
      cur = $1
      sub(/:$/, "", cur)
      printing = (cur == job)
      next
    }
    printing { print }
  ' "$file"
}

job_condition() {
  job_block "$1" "$file" | python3 -c '
import sys, yaml
text = sys.stdin.read()
if sum(line.startswith("    if:") for line in text.splitlines()) != 1:
    sys.exit(0)
value = yaml.safe_load(text).get("if", "")
if not isinstance(value, str):
    sys.exit(0)
if value.startswith("${{") and value.endswith("}}"):
    value = value[3:-2].strip()
print(value)
'
}

# needs_pattern scalar|list: the needs: line a gated job must carry.
# scalar is exactly `needs: changes`; list also accepts a flow list that
# names `changes` as one of its entries, e.g. `needs: [changes, hosts]`.
needs_pattern() {
  case $1 in
    scalar) echo '^[[:space:]]*needs:[[:space:]]*changes[[:space:]]*$' ;;
    list) echo '^[[:space:]]*needs:[[:space:]]*(changes|\[([^]]*,)?[[:space:]]*changes[[:space:]]*(,[^]]*)?\])[[:space:]]*$' ;;
    *) fail "unknown needs form: $1" ;;
  esac
}

assert_gated() {
  local job=$1 needs_form=${2:-scalar} block
  block=$(job_block "$job" "$file")
  if [ -z "$block" ]; then
    fail "job '$job' not found in $file"
  fi
  if ! grep -qE "$(needs_pattern "$needs_form")" <<<"$block"; then
    fail "job '$job' does not declare 'changes' in needs: ($needs_form form)"
  fi
  local if_line expected
  if_line=$(job_condition "$job")
  if [ -z "$if_line" ]; then
    fail "job '$job' declares no if: condition"
  fi
  expected="!cancelled() && (github.event_name != 'pull_request' || needs.changes.result != 'success' || needs.changes.outputs.docs_only != 'true')"
  if [ "$if_line" != "$expected" ]; then
    fail "job '$job' if: does not match the expected fail-open condition exactly (R1/R6/R7/KTD4); got: $if_line"
  fi
  echo "check-workflow-docs-skip: ok - job '$job' is gated on the changes job (R1/R6/R7/KTD4)"
}

assert_unconditional() {
  local job=$1 block
  block=$(job_block "$job" "$file")
  if [ -z "$block" ]; then
    fail "job '$job' not found in $file"
  fi
  if grep -qE '^[[:space:]]*if:' <<<"$block"; then
    fail "job '$job' declares an if: condition; it must always run (R2)"
  fi
  if grep -qE '^[[:space:]]*needs:' <<<"$block"; then
    fail "job '$job' declares needs:; it must not depend on the classifier"
  fi
  echo "check-workflow-docs-skip: ok - job '$job' runs unconditionally"
}

# assert_docs_only_only <job>: the complement of assert_gated's condition
# -- this job runs ONLY when the classifier succeeded and found a genuine
# docs-only PR, i.e. only in the one case flake-check/build are skipped
# and nothing else would have exercised it.
assert_docs_only_only() {
  local job=$1 block
  block=$(job_block "$job" "$file")
  if [ -z "$block" ]; then
    fail "job '$job' not found in $file"
  fi
  if ! grep -qE '^[[:space:]]*needs:[[:space:]]*changes[[:space:]]*$' <<<"$block"; then
    fail "job '$job' does not declare 'needs: changes'"
  fi
  local if_line expected
  if_line=$(job_condition "$job")
  if [ -z "$if_line" ]; then
    fail "job '$job' declares no if: condition"
  fi
  expected="!cancelled() && github.event_name == 'pull_request' && needs.changes.result == 'success' && needs.changes.outputs.docs_only == 'true'"
  if [ "$if_line" != "$expected" ]; then
    fail "job '$job' if: does not match the expected docs-only-only condition exactly; got: $if_line"
  fi
  echo "check-workflow-docs-skip: ok - job '$job' runs only on a genuine docs-only PR"
}

# assert_matrix_from <job> <producer> <output> <key>: the job lists the
# producer in needs: and reads its matrix <key> from that job's JSON output
# instead of a literal list.
assert_matrix_from() {
  local job=$1 producer=$2 output=$3 key=$4 block
  block=$(job_block "$job" "$file")
  if ! grep -qE "^[[:space:]]*needs:[[:space:]]*\[([^]]*,)?[[:space:]]*${producer}[[:space:]]*(,[^]]*)?\][[:space:]]*$" <<<"$block"; then
    fail "job '$job' does not list '$producer' in needs:"
  fi
  if ! grep -qE "^[[:space:]]*${key}:[[:space:]]*\\\$\\{\\{[[:space:]]*fromJSON\\(needs\\.${producer}\\.outputs\\.${output}\\)[[:space:]]*\\}\\}[[:space:]]*$" <<<"$block"; then
    fail "job '$job' matrix $key is not fromJSON(needs.$producer.outputs.$output)"
  fi
  echo "check-workflow-docs-skip: ok - $job reads its matrix from the $producer job"
}

# assert_matrix_from_hosts <job> <output>: the job depends on the hosts job
# and reads its matrix from that job's JSON output instead of a literal host
# list (R19).
assert_matrix_from_hosts() {
  local job=$1 output=$2 block
  block=$(job_block "$job" "$file")
  if ! grep -qE '^[[:space:]]*needs:[[:space:]]*\[([^]]*,)?[[:space:]]*hosts[[:space:]]*(,[^]]*)?\][[:space:]]*$' <<<"$block"; then
    fail "job '$job' does not list 'hosts' in needs: (R19/KTD9)"
  fi
  if ! grep -qE "^[[:space:]]*target:[[:space:]]*\\\$\\{\\{[[:space:]]*fromJSON\\(needs\\.hosts\\.outputs\\.$output\\)[[:space:]]*\\}\\}[[:space:]]*\$" <<<"$block"; then
    fail "job '$job' matrix target is not fromJSON(needs.hosts.outputs.$output) (R19/KTD9)"
  fi
  echo "check-workflow-docs-skip: ok - $job reads its matrix from the hosts job (R19/KTD9)"
}

# assert_empty_list_fails <job>: the lister fails on an empty name list,
# because an empty matrix skips its consumer and leaves the run green with
# no evidence. The test, its failure exit, and the output write must appear
# in that order, so a lister that publishes before checking does not pass.
assert_empty_list_fails() {
  local job=$1 block
  block=$(job_block "$job" "$file" | grep -vE '^[[:space:]]*#')
  if ! awk '
    /^[[:space:]]*if \[ "\$names" = "\[\]" \]; then[[:space:]]*$/ { if (!seen_if) seen_if = NR }
    seen_if && !seen_exit && NR > seen_if && /^[[:space:]]*exit 1[[:space:]]*$/ { seen_exit = NR }
    !seen_exit && /GITHUB_OUTPUT/ { early = 1 }
    seen_exit && NR > seen_exit && /names=\$names.*GITHUB_OUTPUT/ { ok = 1 }
    END { exit !(ok && !early) }
  ' <<<"$block"; then
    fail "job '$job' does not fail on an empty name list before publishing it"
  fi
  echo "check-workflow-docs-skip: ok - $job fails on an empty name list"
}

# assert_native_arm: build-linux sends aarch64 targets to the arm runner, so
# no aarch64 output is ever built under emulation (KTD13 in the non-NixOS
# hosts plan).
assert_native_arm() {
  local block expected
  block=$(job_block build-linux "$file")
  expected="runs-on: \${{ matrix.target.system == 'aarch64-linux' && 'ubuntu-24.04-arm' || 'ubuntu-24.04' }}"
  if ! grep -qF -- "$expected" <<<"$block"; then
    fail "job 'build-linux' does not route aarch64 targets to ubuntu-24.04-arm (KTD13)"
  fi
  echo "check-workflow-docs-skip: ok - build-linux builds aarch64 targets on the arm runner (KTD13)"
}

# assert_native_darwin: build-darwin runs on an Apple Silicon macOS runner,
# the only place an aarch64-darwin output can build.
assert_native_darwin() {
  local block
  block=$(job_block build-darwin "$file")
  if ! grep -qE '^[[:space:]]*runs-on:[[:space:]]*macos-15[[:space:]]*$' <<<"$block"; then
    fail "job 'build-darwin' does not run on the macos-15 arm runner"
  fi
  echo "check-workflow-docs-skip: ok - build-darwin builds on the macos-15 arm runner"
}

# assert_darwin_targets: the hosts job feeds every macOS host's two systems and
# every aarch64-darwin check into darwin_targets, the only path by which the
# macOS-only checks run at all, and build-darwin splits each entry with
# globbing off so a target name is never expanded as a pattern.
assert_darwin_targets() {
  local hosts build
  hosts=$(job_block hosts "$file")
  build=$(job_block build-darwin "$file")
  python3 - "$file" <<'PYTHON'
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

text = Path(sys.argv[1]).read_text()
def block(name):
    match = re.search(r"^  " + re.escape(name) + r":\s*\n(.*?)(?=^  [\w-]+:|\Z)", text, re.M | re.S)
    assert match, f"missing job {name}"
    return match[1]

hosts = block("hosts")
match = re.search(r"lists=\$\(nix eval --impure --json --expr '(.*?)'\)", hosts, re.S)
assert match, "hosts list expression missing"
expr = match[1]
fixture = """{
  nixosConfigurations = { north = {}; south-bootstrap = {}; };
  homeConfigurations = {
    home-intel.activationPackage.system = "x86_64-linux";
    home-arm.activationPackage.system = "aarch64-linux";
  };
  systemConfigs = { sys-intel.system = "x86_64-linux"; sys-arm.system = "aarch64-linux"; };
  darwinConfigurations = { mac-one = {}; mac-one-bootstrap = {}; mac-two = {}; mac-two-bootstrap = {}; };
  checks = { aarch64-linux = { linux-one = {}; linux-two = {}; };
    aarch64-darwin = { darwin-one = {}; "darwin-*" = {}; }; };
}"""
expr, count = re.subn(r"builtins\.getFlake \(toString \./\.\)", lambda _: fixture, expr)
assert count == 1, "fixture did not replace actual flake read"
result = subprocess.run(["nix", "--extra-experimental-features", "nix-command", "eval", "--store", "dummy://", "--json", "--expr", expr], text=True, capture_output=True)
assert result.returncode == 0, result.stderr
lists = json.loads(result.stdout)
expected_linux = [
    {"attr": "homeConfigurations.home-arm.activationPackage", "system": "aarch64-linux"},
    {"attr": "homeConfigurations.home-intel.activationPackage", "system": "x86_64-linux"},
    {"attr": "systemConfigs.sys-arm", "system": "aarch64-linux"},
    {"attr": "systemConfigs.sys-intel", "system": "x86_64-linux"},
    {"attr": "checks.aarch64-linux.linux-one", "system": "aarch64-linux"},
    {"attr": "checks.aarch64-linux.linux-two", "system": "aarch64-linux"},
]
expected_darwin = [
    "darwinConfigurations.mac-one.system darwinConfigurations.mac-one-bootstrap.system",
    "darwinConfigurations.mac-two.system darwinConfigurations.mac-two-bootstrap.system",
    "checks.aarch64-darwin.darwin-*", "checks.aarch64-darwin.darwin-one",
]
assert lists == {"targets": ["north", "south-bootstrap"], "linux_targets": expected_linux,
                 "darwin_targets": expected_darwin}, f"hosts matrix outputs differ: {lists}"
with tempfile.TemporaryDirectory() as tmp:
    Path(tmp, "checks.aarch64-darwin.darwin-expanded").touch()
    for job, entries in [("build", lists["targets"]), ("build-linux", expected_linux),
                         ("build-darwin", expected_darwin)]:
        body = block(job)
        runs = list(re.finditer(r"^        run: (.*?)(?=^      -|\Z)", body, re.M | re.S))
        run = next((run for run in runs if "nix build" in run[1]), None)
        assert run, f"{job}: missing build script"
        script = run[1]
        if script.startswith("|\n"):
            script = "\n".join(line[10:] for line in script[2:].splitlines())
        assert "nix build" in script, f"{job}: no actual build call to record"
        for entry in entries:
            env = dict(os.environ, RECORD=str(Path(tmp, "record")))
            if job == "build-linux":
                env["ATTR"] = entry["attr"]
                want = [".#" + entry["attr"]]
            else:
                env["TARGET"] = entry
                want = ([".#nixosConfigurations." + entry + ".config.system.build.toplevel"]
                        if job == "build" else [".#" + attr for attr in entry.split()])
            recorder = 'nix() { printf "%s\\0" "$@" > "$RECORD"; }; export -f nix\n'
            completed = subprocess.run(["bash", "-eu", "-c", recorder + script], cwd=tmp, env=env,
                                       text=True, capture_output=True)
            assert completed.returncode == 0, completed.stderr
            args = Path(env["RECORD"]).read_bytes().decode().split("\0")[:-1]
            targets = [arg for arg in args if arg.startswith(".#")]
            assert targets == want, f"{job}: recorded targets {targets}, expected {want}"
print("check-workflow-docs-skip: ok - actual workflow list and build consumers")
PYTHON
  echo "check-workflow-docs-skip: ok - darwin_targets carries the macOS hosts and checks"
}

assert_gated flake-check
assert_gated hosts
assert_gated build list
assert_gated build-linux list
assert_matrix_from_hosts build targets
assert_matrix_from_hosts build-linux linux_targets
assert_gated build-darwin list
assert_matrix_from_hosts build-darwin darwin_targets
assert_native_darwin
assert_darwin_targets
assert_native_arm
assert_gated check-shard-names
assert_gated check-shards list
assert_empty_list_fails check-shard-names
assert_matrix_from check-shards check-shard-names names name
assert_gated vm-check-names
assert_gated vm-checks list
assert_empty_list_fails vm-check-names
assert_matrix_from vm-checks vm-check-names names name
assert_unconditional fmt
assert_docs_only_only markdown-lint

echo "check-workflow-docs-skip: ok - all wiring assertions passed"
