#!/usr/bin/env bash
# Isolated, network-free verification of the tokscale login auth script.
#
# Renders the auth template via `chezmoi execute-template` (stub op, empty
# config, --source PWD), creates a stub `tokscale` that records its argv,
# points HOME and PATH at a scratch tree, runs the rendered script, and asserts:
#   - the stub secret appears in the `--token` position
#   - the stub receives exactly `login --token <stub-value>`
#   - a nonzero stub exit propagates as a nonzero script exit
#   - the soft-skip path (no tokscale on PATH) prints a warning and exits 0
#
set -euo pipefail

root=${1:-$(pwd)}
scratch_root=${RUNNER_TEMP:-${XDG_RUNTIME_DIR:-"$HOME/.cache"}}
mkdir -p -- "$scratch_root"
scratch=$(mktemp -d "$scratch_root/tokscale-auth.XXXXXX")
trap 'rm -rf -- "$scratch"' EXIT

# --- stub op + empty config so execute-template never hits live 1Password ---
bin="$scratch/bin"
mkdir -p "$bin"
printf '#!/usr/bin/env bash\ncase "${1-}" in whoami) printf dummy@example.invalid;; *) printf dummy-secret;; esac\n' > "$bin/op"
chmod 700 "$bin/op"
: > "$scratch/empty.toml"

# Minimal PATH for `env bash` resolution: must include /usr/bin and /bin but
# must NOT include any directory that holds a real tokscale (e.g. ~/.local/bin).
safe_path="/usr/bin:/bin:/usr/local/bin"

# --- render the auth template ---
auth="$scratch/auth-tokscale.sh"
env PATH="$bin:$safe_path" chezmoi \
  --config "$scratch/empty.toml" \
  --source "$root" \
  execute-template \
  < "$root/.chezmoiscripts/10-auth/run_onchange_after_auth-tokscale.sh.tmpl" \
  > "$auth"
chmod 700 "$auth"

# The rendered script must contain `tokscale login --token` with the stub
# secret in the token position.
grep -qF 'tokscale login --token' "$auth" \
  || { echo "rendered script missing 'tokscale login --token'" >&2; exit 1; }
grep -qF 'TOKEN="dummy-secret"' "$auth" \
  || { echo "rendered script missing the stub secret in the TOKEN assignment" >&2; exit 1; }

# --- happy path: stub tokscale records args ---
home="$scratch/home"
mkdir -p "$home/.config/tokscale"

stub_dir="$scratch/stub-bin"
mkdir -p "$stub_dir"
args_file="$scratch/tokscale-args"
cat > "$stub_dir/tokscale" <<EOF
#!/usr/bin/env bash
printf '%s\\n' "\$*" > '$args_file'
exit 0
EOF
chmod 700 "$stub_dir/tokscale"

# Pre-create the credentials file so the defensive chmod does not trip.
: > "$home/.config/tokscale/credentials.json"

env HOME="$home" PATH="$stub_dir:$bin:$safe_path" bash "$auth"

[ -f "$args_file" ] || { echo "stub tokscale was not invoked" >&2; exit 1; }
read -r stub_args < "$args_file"
[ "$stub_args" = "login --token dummy-secret" ] \
  || { echo "stub received unexpected args: '$stub_args'" >&2; exit 1; }

# --- failure propagation: nonzero stub exit propagates ---
{
  echo '#!/usr/bin/env bash'
  echo 'exit 1'
} > "$stub_dir/tokscale"
chmod 700 "$stub_dir/tokscale"
if env HOME="$home" PATH="$stub_dir:$bin:$safe_path" bash "$auth" 2>"$scratch/fail.err"; then
  echo "script exited 0 despite a nonzero tokscale exit" >&2; exit 1
fi
grep -qF 'failed' "$scratch/fail.err" \
  || { echo "failure message not printed to stderr" >&2; exit 1; }

# --- soft-skip: no tokscale on PATH -> warn and exit 0 ---
empty_bin="$scratch/empty-bin"
mkdir -p "$empty_bin"
if env HOME="$home" PATH="$empty_bin:$bin:$safe_path" bash "$auth" 2>"$scratch/skip.err"; then
  :
else
  echo "script did not exit 0 when tokscale was absent" >&2; exit 1
fi
grep -qF 'skipping token login' "$scratch/skip.err" \
  || { echo "soft-skip warning not printed to stderr" >&2; exit 1; }

echo "tokscale auth: ok"
