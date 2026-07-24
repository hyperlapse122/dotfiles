#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
scratch_root=${RUNNER_TEMP:-${XDG_RUNTIME_DIR:-"$HOME/.cache"}}
mkdir -p -- "$scratch_root"
scratch=$(mktemp -d "$scratch_root/open-design-integration.XXXXXX")
trap 'rm -rf -- "$scratch"' EXIT

rendered_provision=${1:-}
empty_config="$scratch/empty.toml"
target="$scratch/target"
rendered_unit="$scratch/open-design.service"
: >"$empty_config"
mkdir -p "$target"

command -v chezmoi >/dev/null 2>&1 || {
  printf 'open-design integration: chezmoi is required\n' >&2
  exit 1
}
command -v jq >/dev/null 2>&1 || {
  printf 'open-design integration: jq is required\n' >&2
  exit 1
}

render() {
  chezmoi --config "$empty_config" --source "$repo_root" \
    --destination "$target" execute-template
}

# Resolve the root ignore template before focused rendering so host/desktop
# gates cannot remain syntactically broken while direct templates still pass.
render <"$repo_root/.chezmoiignore" >"$scratch/chezmoiignore"

if [[ -n "$rendered_provision" ]]; then
  [[ -f "$rendered_provision" && ! -L "$rendered_provision" ]] || {
    printf 'open-design integration: rendered provisioner is missing or unsafe: %s\n' \
      "$rendered_provision" >&2
    exit 1
  }
else
  rendered_provision="$scratch/build-open-design.sh"
  render <"$repo_root/.chezmoiscripts/60-build/run_onchange_after_build-open-design.sh.tmpl" \
    >"$rendered_provision"
fi

render <"$repo_root/dot_config/systemd/user/open-design.service.tmpl" \
  >"$rendered_unit"

[[ -s "$rendered_provision" ]] || {
  printf 'open-design integration: provisioner rendered empty\n' >&2
  exit 1
}
[[ -s "$rendered_unit" ]] || {
  printf 'open-design integration: systemd unit rendered empty\n' >&2
  exit 1
}

bash -n "$rendered_provision"
bash -n "$repo_root/dot_local/libexec/open-design/executable_service"
bash -n "$repo_root/dot_local/libexec/open-design/executable_ensure-service"
bash -n "$repo_root/dot_local/bin/executable_od"
bash -n "$repo_root/dot_local/bin/executable_open-design"

"$repo_root/.ci/test-open-design-mcp-render.sh"
"$repo_root/.ci/test-open-design-provision.sh" "$rendered_provision"
"$repo_root/.ci/test-open-design-activation.sh" \
  "$repo_root/dot_local/libexec/open-design/executable_service" \
  "$rendered_unit"
"$repo_root/.ci/test-open-design-desktop.sh"

if command -v systemd-analyze >/dev/null 2>&1; then
  # `verify` resolves ExecStart and WorkingDirectory on the current machine.
  # Substitute only those deployed paths in scratch; every other unit directive
  # remains the exact rendered output under test.
  grep -Fx 'ExecStart=%h/.local/libexec/open-design/service' "$rendered_unit"
  grep -Fx 'WorkingDirectory=%h/.local/share/open-design/source' "$rendered_unit"
  sed \
    -e 's|^ExecStart=.*|ExecStart=/bin/true|' \
    -e 's|^WorkingDirectory=.*|WorkingDirectory=/|' \
    "$rendered_unit" >"$scratch/open-design-verify.service"
  systemd-analyze --user verify "$scratch/open-design-verify.service"
fi

printf 'open-design integration tests passed\n'
