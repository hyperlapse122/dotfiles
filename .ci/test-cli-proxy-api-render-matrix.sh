#!/usr/bin/env bash
# Render-matrix verification for the CLIProxyAPI ignore/removal gates (U5).
#
# Renders the root .chezmoiignore and .chezmoiremove on the CURRENT runner OS
# with an empty config and asserts the per-OS presence/absence contract:
#   linux   — quadlet paths managed; macOS config/launcher ignored AND removed
#   darwin  — plist/launcher/config managed; no removal of managed paths
#   windows — provisioner, macOS config, and launcher ignored; nothing else
#   container (linux + CLI_PROXY_API_TEST_EXPECT=container, with the
#             /run/.containerenv marker pre-created by the caller) — quadlets
#             and the 90-services provisioner additionally skipped; only the
#             containers/systemd SUBPATH is gated, never all of containers/.
#
# Never runs chezmoi apply — render-only, per the repo verification policy.
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
scratch_root=${RUNNER_TEMP:-${XDG_RUNTIME_DIR:-"$HOME/.cache"}}
mkdir -p -- "$scratch_root"
scratch=$(mktemp -d "$scratch_root/cli-proxy-api-render-matrix.XXXXXX")
trap 'rm -rf -- "$scratch"' EXIT

: >"$scratch/empty.toml"
mkdir -p "$scratch/target"

command -v chezmoi >/dev/null 2>&1 || {
  printf 'cli-proxy-api render matrix: chezmoi is required\n' >&2
  exit 1
}

render() {
  chezmoi --config "$scratch/empty.toml" --source "$repo_root" \
    --destination "$scratch/target" execute-template
}

os=$(render <<'EOF'
{{ .chezmoi.os }}
EOF
)
os=$(printf '%s' "$os" | tr -d '[:space:]')

render <"$repo_root/.chezmoiignore" >"$scratch/ignore"
render <"$repo_root/.chezmoiremove" >"$scratch/remove"

fail() {
  printf 'cli-proxy-api render matrix (%s): %s\n' "$os" "$*" >&2
  exit 1
}
has()  { grep -qF -- "$1" "$scratch/$2" || fail "expected $2 to contain: $1"; }
hasnt() { ! grep -qF -- "$1" "$scratch/$2" || fail "expected $2 NOT to contain: $1"; }

expect=${CLI_PROXY_API_TEST_EXPECT:-host}

case "$expect" in
  container)
    [[ "$os" == linux ]] || fail "container expectation only runs on linux, got $os"
    # The quadlet subpath and the provisioner are container-skipped...
    has '.config/containers/systemd' ignore
    has '.chezmoiscripts/90-services/*cli-proxy-api*.sh' ignore
    # ...but only the SUBPATH: a whole-dir containers/ gate would strand
    # auth.json and registries.conf.
    hasnt "$HOME/.config/containers" ignore
    grep -qE '^\.config/containers$' "$scratch/ignore" &&
      fail "whole .config/containers dir must not be container-gated"
    ;;
  host) ;;
  *) fail "unknown CLI_PROXY_API_TEST_EXPECT: $expect" ;;
esac

case "$os" in
  linux)
    # Linux manages the quadlets (no ignore lines for them) and removes the
    # old user unit + launcher leftovers.
    if [[ "$expect" == host ]]; then
      hasnt '.config/containers/systemd' ignore
      hasnt 'cli-proxy-api*.sh' ignore
    fi
    has '.config/cli-proxy-api' ignore
    has '.local/libexec/cli-proxy-api-launch' ignore
    has '.config/systemd/user/cli-proxy-api.service' remove
    has '.local/libexec/cli-proxy-api-launch' remove
    ;;
  darwin)
    # macOS manages the plist, launcher, and source config — nothing of the
    # revival may be ignored or removed here.
    hasnt '.config/cli-proxy-api' ignore
    hasnt '.local/libexec/cli-proxy-api-launch' ignore
    hasnt 'cli-proxy-api*.sh' ignore
    hasnt 'cli-proxy-api' remove
    ;;
  windows)
    # Windows receives no partial state (restored historical block).
    has '.chezmoiscripts/90-services/*cli-proxy-api*.sh' ignore
    has '.config/cli-proxy-api' ignore
    has '.local/libexec/cli-proxy-api-launch' ignore
    has '.local/libexec/cli-proxy-api-launch' remove
    hasnt 'cli-proxy-api.service' remove
    ;;
  *) fail "unexpected os: $os" ;;
esac

printf 'cli-proxy-api render matrix (%s, %s): OK\n' "$os" "$expect"
