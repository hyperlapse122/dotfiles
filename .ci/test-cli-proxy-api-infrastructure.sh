#!/bin/sh
# Deterministic selector, provenance, and static infrastructure assertions.
set -eu

root=$(unset CDPATH; cd -- "$(dirname "$0")/.." && pwd)
scratch=${XDG_RUNTIME_DIR:-${HOME}/.cache}/cli-proxy-api-infrastructure-test-$$
trap 'rm -rf "$scratch"' EXIT INT TERM
mkdir -p "$scratch/target"
: > "$scratch/empty.toml"

render_template() {
  chezmoi --config "$scratch/empty.toml" \
    --source "$root" \
    --destination "$scratch/target" \
    execute-template < "$1"
}

render_ref() {
  ref_os=$1
  ref_arch=$2
  cat > "$scratch/ref.tmpl" <<EOF
{{ includeTemplate "cli-proxy-api-ref.tmpl" (dict "ctx" . "os" "$ref_os" "arch" "$ref_arch" "tag" "v7.2.80" "checksums" (include ".ci/fixtures/cli-proxy-api-checksums-v7.2.80.txt")) }}
EOF
  render_template "$scratch/ref.tmpl"
}

assert_ref() {
  ref_os=$1
  ref_arch=$2
  expected_arch=$3
  expected_sha=$4
  ref_json=$(render_ref "$ref_os" "$ref_arch")
  expected_asset=CLIProxyAPI_7.2.80_${ref_os}_${expected_arch}.tar.gz
  printf '%s' "$ref_json" | jq -e \
    --arg asset "$expected_asset" --arg sha "$expected_sha" \
    '.tag == "v7.2.80" and .asset == $asset and .sha256 == $sha and (.identity | startswith("v7.2.80-"))' \
    >/dev/null
  case $(printf '%s' "$ref_json" | jq -r .asset) in
    *_no-plugin*) printf 'no-plugin asset selected\n' >&2; exit 1 ;;
  esac
}

assert_ref linux amd64 amd64 6c973562831c4ace016b057708ccb6529ba88af93fe67841ed109b81fe030b9a
assert_ref linux arm64 aarch64 c86b709019e6a86ca068772a1ec6f528f314030076163655789f8243be928549
assert_ref darwin amd64 amd64 e442331bf90e908adac1da0b5536c360318dd95708f21423705ed0ae6d311fcc
assert_ref darwin arm64 aarch64 7b13a17670a7d24318e3d6a3f24ff38696cf23ab44894fc93fbd53fbb68dfda6

curl -fsSL https://github.com/router-for-me/CLIProxyAPI/releases/download/v7.2.80/checksums.txt \
  > "$scratch/checksums.txt"
cmp "$scratch/checksums.txt" "$root/.ci/fixtures/cli-proxy-api-checksums-v7.2.80.txt"

# A same-tag digest replacement must produce a different identity.
original_identity=$(render_ref linux amd64 | jq -r .identity)
cat > "$scratch/replaced.tmpl" <<'EOF'
{{ $sums := include ".ci/fixtures/cli-proxy-api-checksums-v7.2.80.txt" | replace "6c973562831c4ace016b057708ccb6529ba88af93fe67841ed109b81fe030b9a" "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" -}}
{{ includeTemplate "cli-proxy-api-ref.tmpl" (dict "ctx" . "os" "linux" "arch" "amd64" "tag" "v7.2.80" "checksums" $sums) }}
EOF
replaced_identity=$(render_template "$scratch/replaced.tmpl" | jq -r .identity)
[ "$original_identity" != "$replaced_identity" ]

assert_render_fails() {
  failure_template=$1
  failure_message=$2
  if render_template "$failure_template" > "$scratch/failure.out" 2> "$scratch/failure.err"; then
    printf 'expected resolver render failure\n' >&2
    exit 1
  fi
  grep -F "$failure_message" "$scratch/failure.err" >/dev/null
}

cat > "$scratch/missing.tmpl" <<'EOF'
{{ includeTemplate "cli-proxy-api-ref.tmpl" (dict "ctx" . "os" "linux" "arch" "amd64" "tag" "v7.2.80" "checksums" "deadbeef  other.tar.gz") }}
EOF
assert_render_fails "$scratch/missing.tmpl" 'expected one checksum'

cat > "$scratch/duplicate.tmpl" <<'EOF'
{{ $line := "6c973562831c4ace016b057708ccb6529ba88af93fe67841ed109b81fe030b9a  CLIProxyAPI_7.2.80_linux_amd64.tar.gz" -}}
{{ includeTemplate "cli-proxy-api-ref.tmpl" (dict "ctx" . "os" "linux" "arch" "amd64" "tag" "v7.2.80" "checksums" (printf "%s\n%s" $line $line)) }}
EOF
assert_render_fails "$scratch/duplicate.tmpl" 'expected one checksum'

cat > "$scratch/malformed.tmpl" <<'EOF'
{{ includeTemplate "cli-proxy-api-ref.tmpl" (dict "ctx" . "os" "linux" "arch" "amd64" "tag" "v7.2.80" "checksums" "bad  CLIProxyAPI_7.2.80_linux_amd64.tar.gz") }}
EOF
assert_render_fails "$scratch/malformed.tmpl" 'invalid sha256'

config=$root/dot_config/cli-proxy-api/readonly_config.yaml
upstream=$scratch/config.example.yaml
actual_diff=$scratch/config.diff
curl -fsSL https://raw.githubusercontent.com/router-for-me/CLIProxyAPI/v7.2.80/config.example.yaml > "$upstream"
git diff --no-index --no-prefix --unified=0 "$upstream" "$config" |
  awk '
    /^diff --git / || /^index / { next }
    /^--- / { print "--- upstream/config.example.yaml"; next }
    /^\+\+\+ / { print "+++ dot_config/cli-proxy-api/readonly_config.yaml"; next }
    { print }
  ' > "$actual_diff"
[ -s "$actual_diff" ]
cmp "$actual_diff" "$root/.ci/fixtures/cli-proxy-api-config-v7.2.80.diff"

grep -qx 'host: "127.0.0.1"' "$config"
grep -qx 'port: 8317' "$config"
grep -qx 'auth-dir: "~/.local/share/cli-proxy-api/auth"' "$config"
grep -qx '  secret-key: ""' "$config"
grep -qx '  disable-control-panel: true' "$config"
grep -qx '  disable-auto-update-panel: true' "$config"
grep -qx 'api-keys: \[\]' "$config"
grep -qx 'commercial-mode: true' "$config"
grep -qx '  enabled: false' "$config"
grep -qx 'debug: false' "$config"
grep -qx 'logging-to-file: false' "$config"

launcher=$root/dot_local/libexec/private_executable_cli-proxy-api-launch
grep -F 'CPA_SOURCE_CONFIG' "$launcher" >/dev/null
grep -F 'runtime config mode must be 0400' "$launcher" >/dev/null
grep -F 'PATH=/usr/bin:/bin:/usr/sbin:/sbin' "$launcher" >/dev/null
grep -F 'exec env -i' "$launcher" >/dev/null
grep -F -- '-local-model' "$launcher" >/dev/null
grep -F 'forbidden .env' "$launcher" >/dev/null
grep -F 'Restart=on-failure' "$root/dot_config/systemd/user/readonly_cli-proxy-api.service" >/dev/null
grep -F 'CPA_HOME=%h' "$root/dot_config/systemd/user/readonly_cli-proxy-api.service" >/dev/null
grep -F 'CPA_SOURCE_CONFIG=%h/.config/cli-proxy-api/config.yaml' "$root/dot_config/systemd/user/readonly_cli-proxy-api.service" >/dev/null
grep -F 'CPA_CONFIG=%h/.local/share/cli-proxy-api/runtime/config.yaml' "$root/dot_config/systemd/user/readonly_cli-proxy-api.service" >/dev/null
grep -F 'Environment=LD_AUDIT=' "$root/dot_config/systemd/user/readonly_cli-proxy-api.service" >/dev/null
grep -F 'StandardError=append:%h/.local/share/cli-proxy-api/work/supervisor.log' "$root/dot_config/systemd/user/readonly_cli-proxy-api.service" >/dev/null
launch_agent=$root/Library/LaunchAgents/readonly_dev.h82.cli-proxy-api.plist.tmpl
grep -F '<key>RunAtLoad</key>' "$launch_agent" >/dev/null
if grep -F '<key>KeepAlive</key>' "$launch_agent" >/dev/null; then
  printf 'LaunchAgent must fail closed instead of retrying forever\n' >&2
  exit 1
fi
grep -F '<key>CPA_HOME</key>' "$launch_agent" >/dev/null
grep -F '{{ $home }}/.config/cli-proxy-api/config.yaml' "$launch_agent" >/dev/null
grep -F '{{ $home }}/.local/share/cli-proxy-api/runtime/config.yaml' "$launch_agent" >/dev/null
grep -F '<key>DYLD_INSERT_LIBRARIES</key>' "$launch_agent" >/dev/null
grep -F '<key>StandardErrorPath</key>' "$launch_agent" >/dev/null
if grep -F '<string>/bin/sh</string>' "$launch_agent" >/dev/null; then
  printf 'LaunchAgent must execute the sterile launcher directly\n' >&2
  exit 1
fi
grep -F '[cli-proxy-api]' "$root/.chezmoiexternals/ai-agents.toml" >/dev/null
grep -F 'includeTemplate "cli-proxy-api-ref.tmpl"' "$root/.chezmoiexternals/ai-agents.toml" >/dev/null
grep -F 'op://Private/CLIProxyAPI/Management API Key' "$root/.chezmoidata/cli-proxy-api.yaml" >/dev/null
grep -F 'secret-key: ""' "$config" >/dev/null
reconciler=$root/.chezmoiscripts/90-services/run_after_cli-proxy-api-service.sh.tmpl
grep -F 'Management API credential is missing or invalid' "$reconciler" >/dev/null
grep -F '[ "${#cpa_management_read}" -ge 32 ]' "$reconciler" >/dev/null
grep -F 'CPA_AWK_SECRET' "$reconciler" >/dev/null
grep -F 'CPA_MANAGEMENT_SECRET_SHA256' "$reconciler" >/dev/null
grep -F '/opt/homebrew/bin/op' "$reconciler" >/dev/null
grep -F '/usr/local/bin/op' "$reconciler" >/dev/null
grep -F '"$CPA_OP" read' "$reconciler" >/dev/null
if grep -F 'command -v op' "$reconciler" >/dev/null; then
  printf 'reconciler must resolve op through approved absolute paths\n' >&2
  exit 1
fi
if grep -F 'MANAGEMENT_PASSWORD=' "$reconciler" >/dev/null; then
  printf 'reconciler must not inject MANAGEMENT_PASSWORD\n' >&2
  exit 1
fi

# Infrastructure only: no agent provider/MCP/default points at the localhost
# service, and no operator-facing login/management helper is restored.
for consumer in \
  "$root/.chezmoidata/agents.yaml" \
  "$root/dot_config/opencode/readonly_opencode.json.tmpl" \
  "$root/dot_pi/agent/private_readonly_settings.json.tmpl" \
  "$root/dot_pi/agent/private_readonly_mcp.json.tmpl"; do
  if grep -Eqi 'cli-proxy-api|127[.]0[.]0[.]1:8317' "$consumer"; then
    printf 'unexpected CLIProxyAPI consumer routing in %s\n' "$consumer" >&2
    exit 1
  fi
done
[ -z "$(find "$root/dot_local/bin" -type f -iname '*cli*proxy*' -print | head -n 1)" ]

printf 'cli-proxy-api infrastructure tests passed\n'
