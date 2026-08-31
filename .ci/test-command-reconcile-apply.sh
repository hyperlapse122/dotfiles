#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
scratch_root="${XDG_RUNTIME_DIR:-$HOME/.cache}/agent-scratch"
mkdir -p "$scratch_root"
scratch=$(mktemp -d "$scratch_root/command-reconcile-apply-test.XXXXXX")
trap 'rm -rf -- "$scratch"' EXIT

home_dir="$scratch/home"
mkdir -p "$home_dir/.local/bin"

reconcile_bin="$repo_root/packages/command-reconcile/dist/command-reconcile"
if [[ ! -x "$reconcile_bin" ]]; then
  (cd "$repo_root/packages/command-reconcile" && bun build --compile ./src/cli.ts --outfile ./dist/command-reconcile)
fi

mkdir -p "$home_dir/.local/share/chezmoi-command-sources"
cat >"$home_dir/.local/share/chezmoi-command-sources/code" <<'EOF'
#!/usr/bin/env bash
echo "code-script"
EOF
chmod 0755 "$home_dir/.local/share/chezmoi-command-sources/code"

mkdir -p "$home_dir/.local/share/chezmoi-commands/incomplete/omp"
cat >"$home_dir/.local/share/chezmoi-commands/incomplete/omp/omp" <<'EOF'
#!/usr/bin/env bash
echo "omp-binary"
EOF
chmod 0755 "$home_dir/.local/share/chezmoi-commands/incomplete/omp/omp"

mkdir -p "$home_dir/.local/share/chezmoi-commands/incomplete/foreign-tool"
cat >"$home_dir/.local/share/chezmoi-commands/incomplete/foreign-tool/foreign-tool" <<'EOF'
#!/usr/bin/env bash
echo "foreign-managed-candidate"
EOF
chmod 0755 "$home_dir/.local/share/chezmoi-commands/incomplete/foreign-tool/foreign-tool"

cat >"$home_dir/.local/bin/foreign-tool" <<'EOF'
#!/usr/bin/env bash
echo "foreign-original"
EOF
chmod 0755 "$home_dir/.local/bin/foreign-tool"

cat >"$home_dir/.local/bin/code" <<'EOF'
#!/usr/bin/env bash
echo "legacy-regular-code"
EOF
chmod 0755 "$home_dir/.local/bin/code"

cat >"$scratch/manifest.json" <<EOF
{
  "schemaVersion": "command-manifest/v1",
  "units": [
    {
      "id": "omp",
      "producer": "external",
      "safetyProfile": "native-single-file",
      "proofEligible": true,
      "mutableTree": false,
      "privacy": "public",
      "mode": "0755",
      "commands": [{ "name": "omp" }],
      "identity": "v1.0.0",
      "stagingPath": ".local/share/chezmoi-commands/incomplete/omp"
    },
    {
      "id": "code",
      "producer": "source",
      "safetyProfile": "interpreted",
      "proofEligible": false,
      "mutableTree": false,
      "privacy": "public",
      "mode": "0755",
      "commands": [{ "name": "code" }],
      "identity": "hash-code-1",
      "stagingPath": ".local/share/chezmoi-command-sources/code",
      "legacy": { "path": ".local/bin/code" }
    },
    {
      "id": "foreign-tool",
      "producer": "external",
      "safetyProfile": "native-single-file",
      "proofEligible": true,
      "mutableTree": false,
      "privacy": "public",
      "mode": "0755",
      "commands": [{ "name": "foreign-tool" }],
      "identity": "v1.0.0",
      "stagingPath": ".local/share/chezmoi-commands/incomplete/foreign-tool"
    }
  ]
}
EOF

"$reconcile_bin" reconcile-all --manifest "$scratch/manifest.json" --home "$home_dir"

[[ -L "$home_dir/.local/bin/omp" ]] || {
  printf 'Failed: omp is not a symbolic link\n' >&2
  exit 1
}

[[ -L "$home_dir/.local/bin/code" ]] || {
  printf 'Failed: legacy code was not migrated to a symlink\n' >&2
  exit 1
}

[[ ! -L "$home_dir/.local/bin/foreign-tool" ]] || {
  printf 'Failed: unproven foreign-tool was overwritten\n' >&2
  exit 1
}
[[ $(<"$home_dir/.local/bin/foreign-tool") == *foreign-original* ]] || {
  printf 'Failed: foreign-tool content was modified\n' >&2
  exit 1
}

"$reconcile_bin" reconcile-all --manifest "$scratch/manifest.json" --home "$home_dir" >/dev/null

printf '%s\n' 'command-reconcile apply integration test passed'
