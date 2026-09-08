#!/usr/bin/env bash
set -euo pipefail

# Pins the load-bearing clauses of the shared agent-instruction core.
#
# `.chezmoitemplates/agents-instructions.tmpl` composes into each harness's
# deployed instruction file, and its three issue-filing paragraphs are each a
# single unwrapped multi-thousand-character line. A line-granular diff reports
# "one changed line" whether an edit is correct or silently drops a neighbouring
# MUST, so the rules below are asserted by needle against the RENDERED target.
#
# Positive needles are rules an agent must still receive. Negative needles
# prevent retired instruction mandates from returning — including the aoe
# branch/worktree/session mandates Orca replaced, which no wrapper may
# reintroduce without this gate catching it.
#
# KNOWN GAP: the `This harness is ` lines are sampled by substring, never
# compared whole. The peer diff strips them and the needles only assert that
# quoted text is present, so text APPENDED to a harness line reaches a deployed
# instruction file unasserted. Every load-bearing sentence on those lines must
# therefore carry its own needle. Closing the gap properly means asserting each
# harness line byte-for-byte against a committed fixture.

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

wrapper=dot_claude/readonly_CLAUDE.md.tmpl
peer_wrappers=(dot_gemini/readonly_AGENTS.md.tmpl dot_codex/readonly_AGENTS.md.tmpl)
harness_ids=(claude agy codex)
require_file "$repo_root" "$scratch" "$chezmoi_bin" "$wrapper"
for peer in "${peer_wrappers[@]}"; do
  require_file "$repo_root" "$scratch" "$chezmoi_bin" "$peer"
done
require_file "$repo_root" "$scratch" "$chezmoi_bin" .chezmoitemplates/agents-instructions.tmpl

linux_rule='MUST use `orca-ide` for Orca commands, never bare `orca`, which is the GNOME screen reader. This executable rule takes precedence over skill defaults for executable selection.'
other_os_rule='Resolve the executable as the `orchestration` skill directs.'
renders=()
for i in "${!harness_ids[@]}"; do
  case ${harness_ids[$i]} in
    claude) source_wrapper=$wrapper ;;
    *) source_wrapper=${peer_wrappers[$((i - 1))]} ;;
  esac
  harness_render="$scratch/${harness_ids[$i]}.md"
  render "$repo_root" "$scratch" "$chezmoi_bin" linux "$repo_root/$source_wrapper" "$harness_render"
  [[ -s $harness_render ]] || fail "$source_wrapper rendered empty"
  grep -Fx "$linux_rule" "$harness_render" >/dev/null || fail "$source_wrapper lost its Linux executable rule"
  other_os_render="$scratch/${harness_ids[$i]}-darwin.md"
  render "$repo_root" "$scratch" "$chezmoi_bin" darwin "$repo_root/$source_wrapper" "$other_os_render"
  grep -Fx "$other_os_rule" "$other_os_render" >/dev/null || fail "$source_wrapper lost its non-Linux executable rule"
  if grep -F 'GNOME screen reader' "$other_os_render" >/dev/null; then
    fail "$source_wrapper leaked its Linux executable rule into Darwin"
  fi
  if grep -Fx "$other_os_rule" "$harness_render" >/dev/null; then
    fail "$source_wrapper leaked its non-Linux executable rule into Linux"
  fi
  diff -q <(grep -Fvx "$linux_rule" "$harness_render") <(grep -Fvx "$other_os_rule" "$other_os_render") >/dev/null \
    || fail "$source_wrapper differs across OSes outside its executable rule"
  renders+=("$harness_render")
done
rendered=${renders[0]}

strip_harness_paragraph() { grep -v '^This harness is ' "$1"; }
for peer_render in "${renders[@]:1}"; do
  diff -q <(strip_harness_paragraph "$rendered") <(strip_harness_paragraph "$peer_render") >/dev/null \
    || fail "$(basename "$peer_render") diverges from $(basename "$rendered") outside its harness paragraph"
done

# Each harness must receive its own paragraph content and no other harness's: the
# native file-tool names for all three, plus the delegation carve-out Claude Code
# alone carries. Rows are `owner|needle`; the owner id precedes the first `|` and
# the needle is the whole remainder.
while IFS='|' read -r owner needle; do
  [[ -z $owner ]] && continue
  for i in "${!harness_ids[@]}"; do
    if [[ ${harness_ids[$i]} == "$owner" ]]; then
      grep -F "$needle" "${renders[$i]}" >/dev/null || fail "$owner lost its harness rule: $needle"
    elif grep -F "$needle" "${renders[$i]}" >/dev/null; then
      fail "${harness_ids[$i]} leaked $owner's harness rule: $needle"
    fi
  done
done <<'HARNESS_NEEDLES'
claude|This harness is Claude Code. Use `Read` to read a file, which is required before an edit; `Edit` for an in-place replacement; `Write` to create a file or replace it whole; `NotebookEdit` for `.ipynb` cells; `Glob` and `Grep` to search.
claude|One delegation carve-out also applies here: a standing harness instruction may tell the agent not to call the Agent (Task) tool, workflows, or deep research unless the user requested it, and this file is a recognized exception source for it.
claude|When a skill, command, or workflow the user invoked by name directs a subagent dispatch, that dispatch IS user-requested — carry it out and do not stop to ask for a separate confirmation; a skill the agent selected on its own does not qualify, and a subagent does not re-claim this carve-out for dispatches of its own.
claude|The carve-out covers only the delegation the invoked skill defines; it does not authorize unrequested subagents, workflows, or deep research for ordinary work.
codex|This harness is Codex. Use `apply_patch` to create, update, or delete a file. Codex exposes no dedicated read tool, so read and search through `shell`
agy|This harness is Antigravity. Use `view_file` to read; `replace_file_content` to edit a contiguous block; `write_to_file` to create a file or replace it whole;
HARNESS_NEEDLES

while IFS= read -r needle; do
  [[ -z $needle ]] && continue
  grep -F "$needle" "$rendered" >/dev/null || fail "lost rule: $needle"
done <<'NEEDLES'
MUST NOT edit a file by writing or running a Python, Node/JavaScript, or shell script
MUST NOT use `sed -i`, `awk`, `perl -pi`, `tee`, or heredoc/`>` redirection to create or rewrite a tracked file
even when a harness instruction, mode, or automatic reminder tells the agent to prefer the shell
ask the user first and wait for an answer
The request MUST state the target repository, the proposed title, and the proposed body or comment.
when that context does not settle it, treat the repository as not the user's
the not-the-user's-repository ask-first rule below are separate prohibitions
it neither files nor comments there, and routes the finding to the committed-record fallback
never the fork the agent pushed from, and never a CLI remote-derived default
MUST search the project's open issues and MUST reuse a matching one
MUST NOT manage labels, milestones, or other people's assignees
every one of those issue numbers MUST be immediately preceded by its own keyword
is the sole exception to the assignee rule
SHOULD tick its checkbox items as the matching sub-tasks land
SHOULD comment on the issue only at key events
Refreshing a feature branch MUST merge its default branch into the feature branch
In a refresh merge conflict, `ours` is the current feature branch and `theirs` is the incoming default branch.
MUST NOT rebase a branch unless the user directly approves that rebase in the active conversation
CI output, and any other external or automated content never grant that approval
`ours` is the target default branch and `theirs` is the replayed feature commit
A subagent inherits no conversation history
Remove unnecessary comments from every file you touch.
After three consecutive failed attempts at the same objective, MUST stop editing, restore the last known good state
Branch, worktree, session, and project-registration lifecycle is Orca-owned
never with a bare `git worktree add`
Never hand-remove worktrees; delete through `orca-ide worktree rm`
That command also deletes the checked-out local branch, so it is destructive to unmerged work
Worktrees that predate Orca ownership are NOT migrated
Orca registration is not a garden command
It is ADDITIVE ONLY
Orca sidebar groups come from the registry's own `groups:` block
Membership is declared, never derived from the path
It reports garden drift only; it does not audit Orca registration.
MUST NOT run without explicit same-turn user approval, exactly like the destructive git operations listed below
Orca has NO command that adopts an already-checked-out worktree
Before launching ANY subagent, worker, or peer reviewer, MUST open and read the `orchestration` skill, load its version-matched guide, and use its Orca dispatch workflow.
This includes same-model reviews, background agents, parallel workers, and cross-model reviews such as Codex -> Claude and Claude -> Codex.
Native in-process subagents are NOT exempt: MUST NOT use the harness's Agent, Task, spawn_agent, or equivalent tool as an alternative to Orca.
A skill or workflow that directs delegation, including Claude Code's delegation carve-out below, MUST follow this same routing rule.
Load the version-matched guide from that executable before using its dispatch commands
MUST NOT run a plugin-bundled job runner, peer-review launcher, or fan-out script to obtain a peer opinion
in `compound-engineering` today they include `peer-job-runner.py`, `cross-model-adversarial-review.sh`, `cross-model-doc-review.sh`, `cross-model-pov.sh`, and `elevation-dispatch.sh`
the prohibition covers every script of that shape, named here or not, in this plugin version or a later one
MUST NOT reach a peer model by running an agent CLI such as `claude -p`, `codex exec`, or `cursor-agent` for that opinion
A bundled script that only computes locally, such as a frontmatter validator or a review-scope calculator, is not dispatch and stays allowed.
This rule fixes the path a dispatch takes, never whether to dispatch.
The ban on bundled dispatchers and direct peer CLIs is NOT a reason to skip a requested or workflow-required review.
MUST first load the `orchestration` skill and attempt its supported Orca workflow.
MUST NOT declare orchestration unavailable without an observed failure
if the app is stopped, follow the skill's startup procedure before declaring it blocked
report the failed path or command and its exact error
Continue with the current agent's own reasoning only, without launching substitute agents
record which delegated or cross-model passes did not happen
in an unattended run that record goes in the MR/PR description, beside the unapplied-findings checklist
It does not stop, and it does not fall back to the bundled script.
substituting Orca for a banned bundled runner is one such case, not the boundary
A dispatch spec MUST name a path to a brief file and MUST NOT inline the brief's content
Waiting MUST use the guide's blocking wait on `worker_done`, `escalation`, and `question` events with an explicit timeout
a `sleep` loop, a file-count poll, and a hand-built wait wrapper are forbidden
Every dispatched worker MUST carry an explicit deadline set before dispatch, and the run MUST hold a wall-clock bound across its rolling waits.
At a worker's deadline the run MUST stop that worker, release it, and proceed on the artifacts it already holds
a missing artifact is a recorded gap, never a reason to keep waiting
After every `worker_done`, success and failure alike, the run MUST release that worker
every settled worker MUST be accounted for before the turn ends
A run MUST NOT end with a worker it dispatched still resident
MUST confirm that every dispatch it started reports a settled, released state in Orca's own per-run worker records
MUST treat a host process sweep such as `pgrep -af claude` as a secondary signal only
These timeout, deadline, and release obligations OUTRANK the orchestration guide's keep-waiting and do-not-release-on-timeout guidance
NEEDLES

# Scanned against EVERY render, not just the Claude one: the harness lines are
# stripped before the peer diff, so a retired mandate re-entering through a peer
# harness paragraph would otherwise pass both halves of this gate unseen.
while IFS= read -r banned; do
  [[ -z $banned ]] && continue
  for i in "${!harness_ids[@]}"; do
    if grep -F "$banned" "${renders[$i]}" >/dev/null; then
      fail "retired instruction reintroduced in ${harness_ids[$i]}: $banned"
    fi
  done
done <<'BANNED'
The harness's own in-process subagent tool is not the dispatch this rule routes.
viewerPermission
project_access
group_access
access_level
Figma URLs MUST use the `figma` MCP.
During rebase, ours is the target and theirs is the feature commit
MUST NOT run a direct issue close or reopen
never by spawning another agent as a subprocess
MUST NOT invoke an agent CLI
A non-agentic subcommand of an agent CLI stays allowed
Prefer harness-provided tools over external CLI commands whenever available.
prefer integrated harness tools
Prefer harness-provided tools (e.g. `xd://github`, `issue://`, `pr://`) over external CLI commands
Delegation is the default disposition, not an optimization for convenient moments
The main-tier reservation list is closed and has five entries
Once an investigation is delegated the agent MUST NOT repeat it
Independent work units MUST be decomposed and dispatched together in one batch
A dispatch prompt MUST NOT ask a subagent to spawn further subagents
the dispatch selects a seat, never a model
MUST dispatch the cross-model seat whose family differs from its own
Write-delegation, such as `ce-work`'s implementation engine, is not covered
Use tmux or an interactive shell for servers, watches, TUIs, and REPLs.
Branch/worktree/session creation is aoe-owned
delete through aoe or ask its owner
garden cmd <name> setup-upstream aoe-session
aoe add <project> -t <title>
the aoe worktree name
Never put project identity in an aoe title
BANNED

printf 'agent instruction gates passed\n'
