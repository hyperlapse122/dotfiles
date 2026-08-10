#!/usr/bin/env bash
set -euo pipefail

# Pins the load-bearing clauses of the shared agent-instruction core.
#
# `.chezmoitemplates/agents-instructions.tmpl` composes into the deployed
# ~/.omp/agent/AGENTS.md, and its three issue-filing paragraphs are each a
# single unwrapped multi-thousand-character line. A line-granular diff reports
# "one changed line" whether an edit is correct or silently drops a neighbouring
# MUST, so the rules below are asserted by needle against the RENDERED target.
#
# Positive needles are rules an agent must still receive. Negative needles are
# the mechanical repository-management gate retired on 2026-08-10
# (docs/plans/2026-08-10-001-refactor-remove-unmanaged-repo-guard-plan.md, R9);
# they exist so a future edit cannot quietly reintroduce a permission probe.

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
scratch_parent=${XDG_RUNTIME_DIR:-${HOME:?HOME is required}/.cache}
mkdir -p "$scratch_parent"
scratch=$(mktemp -d "$scratch_parent/agent-instructions.XXXXXX")
trap 'rm -rf -- "$scratch"' EXIT
mkdir -p "$scratch/home" "$scratch/target" "$scratch/bin"
printf '[data]\n' >"$scratch/empty.toml"
printf '#!/usr/bin/env bash\nprintf dummy-secret\n' >"$scratch/bin/op"
chmod +x "$scratch/bin/op"
chezmoi_bin=$(type -P chezmoi)

fail() { printf 'agent instructions: %s\n' "$*" >&2; exit 1; }
# shellcheck source=.ci/lib/render-gate-helpers.sh
source "$repo_root/.ci/lib/render-gate-helpers.sh"

wrapper=dot_omp/private_agent/private_readonly_AGENTS.md.tmpl
require_file "$repo_root" "$scratch" "$chezmoi_bin" "$wrapper"
require_file "$repo_root" "$scratch" "$chezmoi_bin" .chezmoitemplates/agents-instructions.tmpl

rendered="$scratch/AGENTS.md"
render "$repo_root" "$scratch" "$chezmoi_bin" linux "$repo_root/$wrapper" "$rendered"
[[ -s $rendered ]] || fail 'wrapper rendered empty'

# Rules the agent must still receive.
while IFS= read -r needle; do
  [[ -z $needle ]] && continue
  grep -F "$needle" "$rendered" >/dev/null || fail "lost rule: $needle"
done <<'NEEDLES'
ask the user first and wait for an answer
The request MUST state the target repository, the proposed title, and the proposed body or comment.
when that context does not settle it, treat the repository as not the user's
the not-the-user's-repository ask-first rule below are separate prohibitions
it neither files nor comments there, and routes the finding to the committed-record fallback
never the fork the agent pushed from, and never a CLI remote-derived default
MUST search the project's open issues and MUST reuse a matching one
MUST NOT manage labels, milestones, or other people's assignees
MUST NOT run a direct issue close or reopen
every one of those issue numbers MUST be immediately preceded by its own keyword
is the sole exception to the assignee rule
SHOULD tick its checkbox items as the matching sub-tasks land
SHOULD comment on the issue only at key events
NEEDLES

# The retired mechanical gate must not come back.
while IFS= read -r banned; do
  [[ -z $banned ]] && continue
  if grep -F "$banned" "$rendered" >/dev/null; then
    fail "retired repository-management gate reintroduced: $banned"
  fi
done <<'BANNED'
viewerPermission
project_access
group_access
access_level
BANNED

printf 'agent instruction gates passed\n'
