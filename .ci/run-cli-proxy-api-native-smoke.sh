#!/bin/sh
# Run the real CLIProxyAPI archive through the managed launcher and shared probe.
set -eu

root=$(unset CDPATH; cd -- "$(dirname "$0")/.." && pwd)
if [ -z "${CPA_RELEASE_ARCHIVE:-}" ] && [ -z "${CPA_RELEASE_BINARY:-}" ]; then
  printf 'CPA_RELEASE_ARCHIVE or CPA_RELEASE_BINARY is required\n' >&2
  exit 1
fi
base=${RUNNER_TEMP:-${XDG_RUNTIME_DIR:-${HOME}/.cache}}
scratch=$base/cli-proxy-api-native-smoke-$$
pid=
cleanup() {
  if [ -n "$pid" ]; then
    kill "$pid" >/dev/null 2>&1 || true
    wait "$pid" 2>/dev/null || true
  fi
  if [ -n "${historical_dir:-}" ] && [ -d "$historical_dir" ]; then
    chmod 700 "$historical_dir" 2>/dev/null || true
  fi
  rm -rf "$scratch"
}
trap cleanup EXIT INT TERM

home=$scratch/home
candidate_dir=$home/.local/share/cli-proxy-api/versions/native-smoke
config_dir=$home/.config/cli-proxy-api
runtime_dir=$home/.local/share/cli-proxy-api/runtime
mkdir -p "$candidate_dir" "$config_dir" "$runtime_dir" "$home/.local/libexec" \
  "$home/.local/share/cli-proxy-api/auth" "$home/.local/share/cli-proxy-api/work"
chmod 700 "$home/.local/share/cli-proxy-api" \
  "$home/.local/share/cli-proxy-api/versions" "$candidate_dir" "$runtime_dir" \
  "$home/.local/share/cli-proxy-api/auth" "$home/.local/share/cli-proxy-api/work"
historical_dir=$home/.cli-proxy-api
mkdir -m 700 "$historical_dir"
printf 'historical state must remain untouched\n' > "$historical_dir/sentinel"
chmod 600 "$historical_dir/sentinel"
historical_before=$(find "$historical_dir" -print | LC_ALL=C sort)

candidate=$candidate_dir/cli-proxy-api
if [ -n "${CPA_RELEASE_BINARY:-}" ]; then
  case $CPA_RELEASE_BINARY in /*) ;; *) printf 'CPA_RELEASE_BINARY must be absolute\n' >&2; exit 1 ;; esac
  [ -f "$CPA_RELEASE_BINARY" ] || { printf 'release binary does not exist: %s\n' "$CPA_RELEASE_BINARY" >&2; exit 1; }
  cp "$CPA_RELEASE_BINARY" "$candidate"
else
  case $CPA_RELEASE_ARCHIVE in /*) ;; *) printf 'CPA_RELEASE_ARCHIVE must be absolute\n' >&2; exit 1 ;; esac
  [ -f "$CPA_RELEASE_ARCHIVE" ] || { printf 'release archive does not exist: %s\n' "$CPA_RELEASE_ARCHIVE" >&2; exit 1; }
  tar xzf "$CPA_RELEASE_ARCHIVE" -C "$candidate_dir" cli-proxy-api
fi
chmod 500 "$candidate"
ln -s "$candidate_dir" "$home/.local/share/cli-proxy-api/current"
cp "$root/dot_config/cli-proxy-api/readonly_config.yaml" "$config_dir/config.yaml"
chmod 444 "$config_dir/config.yaml"
cp "$root/dot_local/libexec/private_executable_cli-proxy-api-launch" "$home/.local/libexec/cli-proxy-api-launch"
chmod 700 "$home/.local/libexec/cli-proxy-api-launch"

export CPA_HOME="$home"
export CPA_ACTIVE_BINARY="$home/.local/share/cli-proxy-api/current/cli-proxy-api"
export CPA_SOURCE_CONFIG="$config_dir/config.yaml"
export CPA_CONFIG="$runtime_dir/config.yaml"
management_secret=${CPA_MANAGEMENT_SECRET:-native-cli-proxy-api-management-secret-0123456789}
case "$management_secret" in
  *[!A-Za-z0-9._~!@#$%^+=,:/-]*|"") printf 'invalid native Management credential\n' >&2; exit 1 ;;
esac
[ "${#management_secret}" -ge 32 ] || { printf 'native Management credential is too short\n' >&2; exit 1; }
(umask 077; CPA_AWK_SECRET="$management_secret" awk '/^  secret-key: ""$/ { print "  secret-key: \"" ENVIRON["CPA_AWK_SECRET"] "\""; next } { print }' "$CPA_SOURCE_CONFIG" > "$CPA_CONFIG")
chmod 600 "$CPA_CONFIG"
CPA_MANAGEMENT_SECRET="$management_secret"
# shellcheck disable=SC2034
CPA_MANAGEMENT_ENABLED=1
# Pre-place a management.html fixture at the runtime static path so the
# /management.html route serves a local file (disable-control-panel: false in
# the copied config) and the real binary never attempts a GitHub fetch. The
# shared smoke asserts HTTP 200 via CPA_PANEL_ENABLED.
mkdir -m 700 "$runtime_dir/static"
printf '<!doctype html><title>cli-proxy-api panel fixture</title>\n' > "$runtime_dir/static/management.html"
chmod 400 "$runtime_dir/static/management.html"
# shellcheck disable=SC2034
CPA_PANEL_ENABLED=1
export CPA_AUTH_DIR="$home/.local/share/cli-proxy-api/auth"
export CPA_WORK_DIR="$home/.local/share/cli-proxy-api/work"
CPA_JQ=${CPA_JQ_OVERRIDE:-$(command -v jq)}
case $CPA_JQ in /*) ;; *) printf 'CPA_JQ must be absolute\n' >&2; exit 1 ;; esac
[ -x "$CPA_JQ" ] || { printf 'CPA_JQ is not executable: %s\n' "$CPA_JQ" >&2; exit 1; }
export CPA_JQ
export CPA_LOG_FILE="$scratch/process.log"
# shellcheck source=.ci/smoke-cli-proxy-api.sh
. "$root/.ci/smoke-cli-proxy-api.sh"
CPA_EXPECTED_CONFIG_SHA256=$(cpa_sha256 "$CPA_CONFIG")
export CPA_EXPECTED_CONFIG_SHA256
export CPA_SMOKE_MAX_ATTEMPTS=10
export CPA_SMOKE_CANARY=native-cli-proxy-api-request-canary
historical_hash_before=$(cpa_sha256 "$historical_dir/sentinel")
# The native process runs as the same non-root user but cannot read legacy
# state. Any attempted credential consumption is denied rather than merely
# observed after the fact.
chmod 000 "$historical_dir"

HOME="$scratch/ambient-home-canary" \
CPA_HOME=$CPA_HOME CPA_ACTIVE_BINARY=$CPA_ACTIVE_BINARY CPA_SOURCE_CONFIG=$CPA_SOURCE_CONFIG CPA_CONFIG=$CPA_CONFIG \
CPA_BOOTSTRAP=1 CPA_AUTH_DIR=$CPA_AUTH_DIR CPA_WORK_DIR=$CPA_WORK_DIR CPA_JQ=$CPA_JQ \
MANAGEMENT_PASSWORD=environment-canary HOME_JWT=environment-canary \
GITSTORE_GIT_TOKEN=environment-canary OBJECTSTORE_SECRET_KEY=environment-canary \
HTTPS_PROXY=http://environment-canary.invalid OP_SERVICE_ACCOUNT_TOKEN=environment-canary \
ANTHROPIC_API_KEY=environment-canary \
  "$home/.local/libexec/cli-proxy-api-launch" -- > "$CPA_LOG_FILE" 2>&1 &
pid=$!

hash_attempt=0
while ! grep -Eq '^[[:space:]]+secret-key:[[:space:]]*.*[$]2[aby][$][0-9]+[$]' "$CPA_CONFIG"; do
  hash_attempt=$((hash_attempt + 1))
  [ "$hash_attempt" -lt 15 ] || { printf 'runtime config was not bcrypt-hashed\n' >&2; exit 1; }
  sleep 1
done
runtime_config=$(cat "$CPA_CONFIG")
case "$runtime_config" in
  *"$management_secret"*) printf 'runtime config retained plaintext credential\n' >&2; exit 1 ;;
esac
unset runtime_config
chmod 400 "$CPA_CONFIG"
CPA_EXPECTED_CONFIG_SHA256=$(cpa_sha256 "$CPA_CONFIG")
export CPA_EXPECTED_CONFIG_SHA256

cpa_smoke "$pid"
kill -0 "$pid"

chmod 700 "$historical_dir"
[ "$(cpa_sha256 "$historical_dir/sentinel")" = "$historical_hash_before" ]
[ "$(find "$historical_dir" -print | LC_ALL=C sort)" = "$historical_before" ]
if find "$home" -type f ! -path "$candidate" -exec grep -F -l -- "$CPA_SMOKE_CANARY" {} + 2>/dev/null | grep -q .; then
  printf 'request canary escaped into the isolated managed home\n' >&2
  exit 1
fi

# Read the environment only after the semantic probe proves the launcher has
# exec'd the expected binary. Assert forbidden names without printing values.
if [ -r "/proc/$pid/environ" ]; then
  child_env=$(tr '\0' '\n' < "/proc/$pid/environ")
else
  child_env=$(ps eww -p "$pid" -o command=)
fi
for forbidden in MANAGEMENT_PASSWORD HOME_JWT GITSTORE_GIT_TOKEN OBJECTSTORE_SECRET_KEY HTTPS_PROXY OP_SERVICE_ACCOUNT_TOKEN ANTHROPIC_API_KEY CPA_HOME CPA_ACTIVE_BINARY CPA_SOURCE_CONFIG CPA_CONFIG CPA_BOOTSTRAP CPA_AUTH_DIR CPA_WORK_DIR CPA_JQ CPA_EXPECTED_CONFIG_SHA256 CPA_SMOKE_MAX_ATTEMPTS CPA_SMOKE_CANARY; do
  if printf '%s\n' "$child_env" | grep -q "${forbidden}="; then
    printf 'native child environment leaked %s\n' "$forbidden" >&2
    exit 1
  fi
done
unset child_env

grep -F 'Local model mode: using embedded model catalogs' "$CPA_LOG_FILE" >/dev/null

printf 'cli-proxy-api native smoke passed on %s/%s\n' "$(uname -s)" "$(uname -m)"
