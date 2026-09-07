# shellcheck shell=bash
# .ci/lib/render-scratch.sh -- offline chezmoi render scratch, sourced (never
# executed directly).
#
# Several gates render templates with `chezmoi execute-template` against a
# throwaway destination. They all need the same three things, and were each
# carrying their own copy of the setup:
#
#   * a private scratch directory under the agent-scratch root, removed on exit
#   * a stub `op` on PATH, because .chezmoiexternals/system.toml reaches
#     facts.tmpl which shells out to 1Password on some paths
#   * an empty chezmoi config, so the render never reads the real one
#
# The `op` stub answers `whoami` as well as a bare secret read: facts.tmpl
# calls both, and a stub that only handles the read leaves `whoami` returning
# the secret string, which is a confusing way to fail.
#
# Usage, from a gate:
#
#   . "$repo_root/.ci/lib/render-scratch.sh"
#   setup_render_scratch my-gate-name    # sets $scratch, installs the EXIT trap
#
# The caller keeps ownership of what it renders and how; this only builds the
# sandbox those renders run in.

setup_render_scratch() {
  local name=${1:?setup_render_scratch: a scratch name is required}
  local scratch_root=${XDG_RUNTIME_DIR:-$HOME/.cache}/agent-scratch
  mkdir -p -- "$scratch_root"
  scratch=$(mktemp -d "$scratch_root/$name.XXXXXX")
  # shellcheck disable=SC2064  # expand $scratch now: the trap must name this run's dir
  trap "rm -rf -- '$scratch'" EXIT
  mkdir -p -- "$scratch/bin" "$scratch/target"
  printf '#!/usr/bin/env bash\ncase "${1-}" in whoami) printf dummy@example.invalid;; *) printf dummy-secret;; esac\n' >"$scratch/bin/op"
  chmod 700 "$scratch/bin/op"
  printf '[data]\n' >"$scratch/empty.toml"
}
