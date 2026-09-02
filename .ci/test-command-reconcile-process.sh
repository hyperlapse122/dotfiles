#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
scratch_root="${XDG_RUNTIME_DIR:-$HOME/.cache}/agent-scratch"
mkdir -p "$scratch_root"
scratch=$(mktemp -d "$scratch_root/command-reconcile-process-test.XXXXXX")
trap 'rm -rf -- "$scratch"' EXIT

home_dir="$scratch/home"
mkdir -p "$home_dir"

reconcile_bin="$repo_root/packages/command-reconcile/dist/command-reconcile"
(cd "$repo_root/packages/command-reconcile" && bun build --compile ./src/cli.ts --outfile ./dist/command-reconcile)

staging_unit="$home_dir/.local/share/chezmoi-commands/incomplete/agent-browser"
mkdir -p "$staging_unit"
cat >"$staging_unit/agent-browser" <<'EOF'
#!/usr/bin/env bash
echo "v1-binary"
EOF
chmod 0755 "$staging_unit/agent-browser"

cat >"$scratch/manifest-v1.json" <<EOF
{
  "schemaVersion": "command-manifest/v1",
  "units": [
    {
      "id": "agent-browser",
      "producer": "external",
      "safetyProfile": "native-single-file",
      "proofEligible": true,
      "mutableTree": false,
      "privacy": "public",
      "mode": "0755",
      "commands": [{ "name": "agent-browser" }],
      "identity": "v1.0.0",
      "stagingPath": ".local/share/chezmoi-commands/incomplete/agent-browser"
    }
  ]
}
EOF

"$reconcile_bin" activate-unit --manifest "$scratch/manifest-v1.json" --unit agent-browser --home "$home_dir"

( exec 3< "$home_dir/.local/bin/agent-browser"; exec sleep 30 ) &
proc_pid=$!
trap 'kill -9 "$proc_pid" 2>/dev/null || true; rm -rf -- "$scratch"' EXIT

sleep 0.2

cat >"$staging_unit/agent-browser" <<'EOF'
#!/usr/bin/env bash
echo "v2-binary"
EOF
chmod 0755 "$staging_unit/agent-browser"

cat >"$scratch/manifest-v2.json" <<EOF
{
  "schemaVersion": "command-manifest/v1",
  "units": [
    {
      "id": "agent-browser",
      "producer": "external",
      "safetyProfile": "native-single-file",
      "proofEligible": true,
      "mutableTree": false,
      "privacy": "public",
      "mode": "0755",
      "commands": [{ "name": "agent-browser" }],
      "identity": "v2.0.0",
      "stagingPath": ".local/share/chezmoi-commands/incomplete/agent-browser"
    }
  ]
}
EOF

"$reconcile_bin" activate-unit --manifest "$scratch/manifest-v2.json" --unit agent-browser --home "$home_dir"

"$reconcile_bin" reconcile-all --manifest "$scratch/manifest-v2.json" --home "$home_dir" --prune >/dev/null

[[ -d "$home_dir/.local/lib/commands/store/agent-browser/v1.0.0" ]] || {
  printf 'Failed: v1.0.0 was pruned while process %s was holding it open\n' "$proc_pid" >&2
  exit 1
}

kill -9 "$proc_pid" 2>/dev/null || true
wait "$proc_pid" 2>/dev/null || true
sleep 0.2

"$reconcile_bin" reconcile-all --manifest "$scratch/manifest-v2.json" --home "$home_dir" --prune >/dev/null

[[ ! -d "$home_dir/.local/lib/commands/store/agent-browser/v1.0.0" ]] || {
  printf 'Failed: v1.0.0 was not pruned after process exited\n' >&2
  exit 1
}

[[ -d "$home_dir/.local/lib/commands/store/agent-browser/v2.0.0" ]] || {
  printf 'Failed: active v2.0.0 was removed\n' >&2
  exit 1
}

printf 'command-reconcile real process safety and prune test passed\n'
