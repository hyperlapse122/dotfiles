#!/usr/bin/env bash
# Isolated render verification for the CLIProxyAPI quadlet integration (U2/U4).
#
# Renders the quadlets, the dual-OS provisioner, and the macOS launchd plist
# through `chezmoi execute-template` with a stub `op` and asserts the layout
# invariants (AE6): image refs resolve from the release lock, every volume is
# a :Z-labeled bind under the data root, each container mounts only its own
# subdirs, all published ports are loopback-only, and no secret leaks into the
# onchange fingerprint. Never runs chezmoi apply, podman, or systemctl —
# per the repo's non-deployment verification policy.
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
scratch_root=${RUNNER_TEMP:-${XDG_RUNTIME_DIR:-"$HOME/.cache"}}
mkdir -p -- "$scratch_root"
scratch=$(mktemp -d "$scratch_root/cli-proxy-api-integration.XXXXXX")
trap 'rm -rf -- "$scratch"' EXIT

: >"$scratch/empty.toml"
mkdir -p "$scratch/target" "$scratch/bin" "$scratch/fakehome"

# Newline-free dummy secret, per the AGENTS.md stub recipe.
printf '#!/usr/bin/env bash\ncase "${1-}" in whoami) printf dummy@example.invalid;; *) printf dummy-secret;; esac\n' \
  >"$scratch/bin/op"
chmod 700 "$scratch/bin/op"

command -v chezmoi >/dev/null 2>&1 || {
  printf 'cli-proxy-api integration: chezmoi is required\n' >&2
  exit 1
}

render() {
  env HOME="$scratch/fakehome" PATH="$scratch/bin:$PATH" \
    chezmoi --config "$scratch/empty.toml" --source "$repo_root" \
    --destination "$scratch/target" execute-template
}

fail() {
  printf 'cli-proxy-api integration: %s\n' "$*" >&2
  exit 1
}

# --- Quadlet renders ---------------------------------------------------------
render <"$repo_root/dot_config/containers/systemd/cli-proxy-api.container.tmpl" \
  >"$scratch/cpa.container"
render <"$repo_root/dot_config/containers/systemd/cpa-manager-plus.container.tmpl" \
  >"$scratch/cpamp.container"
render <"$repo_root/dot_config/containers/systemd/cli-proxy-api.network" \
  >"$scratch/cpa.network"

[[ -s "$scratch/cpa.container" ]] || fail "cli-proxy-api.container rendered empty"
[[ -s "$scratch/cpamp.container" ]] || fail "cpa-manager-plus.container rendered empty"
grep -qx '\[Network\]' "$scratch/cpa.network" || fail ".network must be a bare [Network]"

has() { grep -qE -- "$1" "$2" || fail "$3 (in $2)"; }

# Image refs resolve from the release lock as name:tag@digest.
has '^Image=docker\.io/eceasy/cli-proxy-api:latest@sha256:[0-9a-f]{64}$' \
  "$scratch/cpa.container" "CPA image ref must resolve from the lock"
has '^Image=ghcr\.io/seakee/cpa-manager-plus:latest@sha256:[0-9a-f]{64}$' \
  "$scratch/cpamp.container" "CPAMP image ref must resolve from the lock"

# Loopback-only published ports.
has '^PublishPort=127\.0\.0\.1:8317:8317$' "$scratch/cpa.container" "proxy port must be loopback"
has '^PublishPort=127\.0\.0\.1:18317:18317$' "$scratch/cpamp.container" "panel port must be loopback"
grep -E '^PublishPort=' "$scratch/cpa.container" "$scratch/cpamp.container" |
  grep -qv '127\.0\.0\.1:' &&
  fail "every published port must be loopback-only"

# Volumes: :Z-labeled binds under %h only — no anonymous volumes, and each
# container mounts only its own subdirs (AE6).
for f in "$scratch/cpa.container" "$scratch/cpamp.container"; do
  grep -E '^Volume=' "$f" | grep -qvE '^Volume=%h/[^=]+:Z$' &&
    fail "non-bind or unlabeled volume in $f"
done
[[ $(grep -c '^Volume=%h/[^=]*/config:/CLIProxyAPI/config:Z$' "$scratch/cpa.container") -eq 1 ]] ||
  fail "CPA must mount the config subdir"
[[ $(grep -c '^Volume=%h/[^=]*/auth:/CLIProxyAPI/auth:Z$' "$scratch/cpa.container") -eq 1 ]] ||
  fail "CPA must mount the auth subdir"
[[ $(grep -c '^Volume=' "$scratch/cpa.container") -eq 2 ]] ||
  fail "CPA must mount exactly config/ and auth/"
[[ $(grep -c '^Volume=%h/[^=]*/cpamp:/data:Z$' "$scratch/cpamp.container") -eq 1 ]] ||
  fail "CPAMP must mount the cpamp subdir"
[[ $(grep -c '^Volume=' "$scratch/cpamp.container") -eq 1 ]] ||
  fail "CPAMP must mount only cpamp/"

# Ordering and lifecycle.
has '^After=cli-proxy-api\.service$' "$scratch/cpamp.container" \
  "CPAMP must stop before CPA (After=)"
has '^WantedBy=default\.target$' "$scratch/cpa.container" "CPA must start at login"
has '^WantedBy=default\.target$' "$scratch/cpamp.container" "CPAMP must start at login"

# --- Provisioner render ------------------------------------------------------
render <"$repo_root/.chezmoiscripts/90-services/run_onchange_after_provision-cli-proxy-api.sh.tmpl" \
  >"$scratch/provision.sh"
[[ -s "$scratch/provision.sh" ]] || fail "provisioner rendered empty"
bash -n "$scratch/provision.sh"

# The management and panel-admin secrets render into exactly two heredoc
# sites (the transient script body) and never into a fingerprint comment.
[[ $(grep -c 'dummy-secret' "$scratch/provision.sh") -eq 2 ]] ||
  fail "expected exactly the two credential render sites"
grep -n 'dummy-secret' "$scratch/provision.sh" | grep -q '^[0-9]*:[[:space:]]*#' &&
  fail "secret leaked into a comment line (fingerprint?)"
has 'systemctl --user restart cli-proxy-api\.service cpa-manager-plus\.service' \
  "$scratch/provision.sh" "provisioner must restart both services on rollout"
has '\.rolled-out-refs' "$scratch/provision.sh" "rollout must be stamp-gated"

# --- macOS plist render ------------------------------------------------------
render <"$repo_root/Library/LaunchAgents/readonly_dev.h82.cli-proxy-api.plist.tmpl" \
  >"$scratch/cpa.plist"
has '\.local/bin/cli-proxy-api</string>' "$scratch/cpa.plist" \
  "plist must point at the externals-managed binary"
has 'cli-proxy-api/config/config\.yaml</string>' "$scratch/cpa.plist" \
  "plist must point at the seeded runtime config"

# --- No render-time network builtins in the revived templates ----------------
# The old cli-proxy-api-ref.tmpl / panel-ref.tmpl templates (gitHubLatestRelease
# / curl at render time) must stay removed.
for f in \
  "$repo_root/Library/LaunchAgents/readonly_dev.h82.cli-proxy-api.plist.tmpl" \
  "$repo_root/.chezmoiexternals/ai-agents.toml" \
  "$repo_root/dot_config/containers/systemd/cli-proxy-api.container.tmpl" \
  "$repo_root/dot_config/containers/systemd/cpa-manager-plus.container.tmpl"; do
  grep -qE 'gitHubLatestRelease|gitHubLatestTag|"curl"|"wget"' "$f" &&
    fail "render-time network resolution found in $f"
done

# The externals file must render cleanly on linux (the darwin block skips) and
# no template-comment body may leak into the output TOML.
render <"$repo_root/.chezmoiexternals/ai-agents.toml" >"$scratch/ai-agents.toml"
grep -q 'dotagents install' "$scratch/ai-agents.toml" &&
  fail "template comment text leaked into the rendered externals file"

printf 'cli-proxy-api integration tests passed\n'
