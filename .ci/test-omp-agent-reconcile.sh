#!/usr/bin/env bash
set -euo pipefail

auth_script=${1:?usage: test-omp-agent-reconcile.sh AUTH_SCRIPT PLUGIN_SCRIPT}
plugin_script=${2:?usage: test-omp-agent-reconcile.sh AUTH_SCRIPT PLUGIN_SCRIPT}
scratch_root=${XDG_RUNTIME_DIR:-"$HOME/.cache"}
scratch=$(mktemp -d "$scratch_root/omp-agent-reconcile.XXXXXX")
cleanup() {
  rm -rf -- "$scratch"
}
trap cleanup EXIT

home="$scratch/home"
fake_bin="$scratch/bin"
mkdir -p "$home/.omp/agent" "$fake_bin"

cat >"$home/.omp/agent/.env" <<'EOF'
# user-owned values stay byte-identical
OTHER_TOKEN='keep me'
ZAI_API_KEY=stale
ZAI_API_KEY="duplicate"
EOF
chmod 0644 "$home/.omp/agent/.env"

env HOME="$home" bash "$auth_script"

auth="$home/.omp/agent/.env"
[[ $(stat -c '%a' "$auth") == 600 ]]
[[ $(grep -c '^ZAI_API_KEY=' "$auth") -eq 1 ]]
grep -F "# user-owned values stay byte-identical" "$auth" >/dev/null
grep -F "OTHER_TOKEN='keep me'" "$auth" >/dev/null
grep -F 'dummy-secret' "$auth" >/dev/null

printf 'NOT A DOTENV ASSIGNMENT\n' >"$auth"
if env HOME="$home" bash "$auth_script" >"$scratch/malformed.out" 2>"$scratch/malformed.err"; then
  printf 'auth reconcile accepted malformed dotenv input\n' >&2
  exit 1
fi
[[ $(cat "$auth") == 'NOT A DOTENV ASSIGNMENT' ]]
grep -F 'refusing malformed dotenv line' "$scratch/malformed.err" >/dev/null

referent="$scratch/referent"
printf 'do not overwrite\n' >"$referent"
rm "$auth"
ln -s "$referent" "$auth"
if env HOME="$home" bash "$auth_script" >"$scratch/auth.out" 2>"$scratch/auth.err"; then
  printf 'auth reconcile accepted a symlink target\n' >&2
  exit 1
fi
[[ $(cat "$referent") == 'do not overwrite' ]]
grep -F 'unsafe target' "$scratch/auth.err" >/dev/null

source="$home/.local/share/compound-engineering/v3.20.0"
mkdir -p "$source/.claude-plugin"
printf '{"name":"compound-engineering-plugin"}\n' >"$source/.claude-plugin/marketplace.json"
cat >"$fake_bin/omp" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$OMP_CALLS"
EOF
chmod 0755 "$fake_bin/omp"

OMP_CALLS="$scratch/omp.calls" env HOME="$home" PATH="$fake_bin:$PATH" bash "$plugin_script"

mapfile -t calls <"$scratch/omp.calls"
[[ ${#calls[@]} -eq 2 ]]
[[ ${calls[0]} == "plugin marketplace add $source" ]]
[[ ${calls[1]} == "plugin install --scope user compound-engineering@compound-engineering-plugin" ]]

printf 'omp auth and plugin reconcile tests passed\n'
