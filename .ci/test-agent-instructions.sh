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
# Every paragraph this gate protects is compared WHOLE against a committed
# fixture, so an appended clause that reverses a MUST fails even when every
# needle still matches. Editing any of that prose means updating its fixture in
# the same commit. The fixtures are:
#
#   harness-runs-<harness>.txt  the `This harness runs ` model-tuning line
#   harness-is-<harness>.txt    every `This harness is ` line for that harness
#   lfg-autonomy.txt            the `lfg` autonomy paragraph
#   workflow-required-autonomy.txt  the workflow-required-step paragraph
#
# The `This harness is ` fixtures close a former gap: the peer diff strips those
# lines and the needles only assert that quoted text is present, so text APPENDED
# to a harness line used to reach a deployed instruction file unasserted. Claude
# renders two such lines; the fixture holds both, in order.
#
# The two autonomy paragraphs are additionally ANCHORED to each other: the
# workflow-required-step paragraph must render exactly two lines below the `lfg`
# paragraph. Without that, a copy of the fixture text parked elsewhere would
# satisfy the whole-line comparison while the paragraph in the operative position
# was rewritten, and an inserted heading could move the paragraph out of the
# section its own "above" references depend on.
#
# The darwin arm of that loop is belt-and-braces: the cross-OS diff below already
# forces the two renders to be byte-identical outside the executable rule, so the
# darwin assertions cannot fail alone. They are kept so that weakening the
# cross-OS diff cannot silently drop darwin coverage.
#
# RESIDUAL, not closed: a contradicting sentence added elsewhere in the shared
# body is not caught by any fixture, because no fixture bounds a section. The
# BANNED list below is the mechanism for a retired or forbidden phrasing, and it
# matches literal text only. Semantic consistency across the whole file is a
# review obligation, not a machine-checked one.

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
# A render-assertion failure records and continues, so a single lost sentence
# reports BOTH its fixture mismatch and the requirement needle it dropped. Only
# these assertions are soft; every other `fail` still exits at once, because the
# checks after them read files an earlier `fail` proved present.
soft_failed=0
soft_fail() { printf 'agent instructions: %s\n' "$*" >&2; soft_failed=1; }
# shellcheck source=.ci/lib/render-gate-helpers.sh
source "$repo_root/.ci/lib/render-gate-helpers.sh"

wrapper=dot_claude/readonly_CLAUDE.md.tmpl
peer_wrappers=(
  dot_gemini/readonly_AGENTS.md.tmpl
  dot_codex/readonly_AGENTS.md.tmpl
  dot_omp/private_agent/private_readonly_AGENTS.md.tmpl
)
harness_ids=(claude agy codex omp)
require_file "$repo_root" "$scratch" "$chezmoi_bin" "$wrapper"
for peer in "${peer_wrappers[@]}"; do
  require_file "$repo_root" "$scratch" "$chezmoi_bin" "$peer"
done
require_file "$repo_root" "$scratch" "$chezmoi_bin" .chezmoitemplates/agents-instructions.tmpl
lfg_fixture_path=".ci/fixtures/agent-instructions/lfg-autonomy.txt"
workflow_fixture_path=".ci/fixtures/agent-instructions/workflow-required-autonomy.txt"
require_file "$repo_root" "$scratch" "$chezmoi_bin" "$lfg_fixture_path"
require_file "$repo_root" "$scratch" "$chezmoi_bin" "$workflow_fixture_path"
lfg_fixture="$repo_root/$lfg_fixture_path"
workflow_fixture="$repo_root/$workflow_fixture_path"

# The darwin-leak sentinel must be a phrase the Linux rule actually contains, or
# the leak assertion asserts nothing. `/usr/bin/orca` is Linux-only and appears
# nowhere else in the core, so it moves with `linux_rule` in one edit.
linux_rule='MUST use `orca-ide` for Orca commands, never bare `orca`, because bare `orca` resolves by PATH order and reaches `/usr/bin/orca`, the GNOME screen reader, on any host where no wrapper precedes `/usr/bin`. This executable rule takes precedence over skill defaults for executable selection.'
linux_only_sentinel='`/usr/bin/orca`'
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
  grep -F "$linux_only_sentinel" "$harness_render" >/dev/null \
    || fail "$source_wrapper lost the Linux-only sentinel, so the Darwin leak check is vacuous"
  if grep -F "$linux_only_sentinel" "$other_os_render" >/dev/null; then
    fail "$source_wrapper leaked its Linux executable rule into Darwin"
  fi
  if grep -Fx "$other_os_rule" "$harness_render" >/dev/null; then
    fail "$source_wrapper leaked its non-Linux executable rule into Linux"
  fi
  diff -q <(grep -Fvx "$linux_rule" "$harness_render") <(grep -Fvx "$other_os_rule" "$other_os_render") >/dev/null \
    || fail "$source_wrapper differs across OSes outside its executable rule"
  # The model-tuning line is compared whole, so an appended sentence cannot ride
  # in behind the peer diff that strips it. The fixture is the expectation; a
  # deliberate wording change updates it in the same commit.
  runs_fixture_path=".ci/fixtures/agent-instructions/harness-runs-${harness_ids[$i]}.txt"
  require_file "$repo_root" "$scratch" "$chezmoi_bin" "$runs_fixture_path"
  runs_fixture="$repo_root/$runs_fixture_path"
  runs_line="$scratch/${harness_ids[$i]}-runs.txt"
  grep '^This harness runs ' "$harness_render" >"$runs_line" || true
  [[ $(wc -l <"$runs_line") -eq 1 ]] \
    || fail "${harness_ids[$i]} must render exactly one 'This harness runs ' line"
  diff -q "$runs_fixture" "$runs_line" >/dev/null \
    || fail "${harness_ids[$i]} model-tuning line differs from $runs_fixture"
  is_fixture_path=".ci/fixtures/agent-instructions/harness-is-${harness_ids[$i]}.txt"
  require_file "$repo_root" "$scratch" "$chezmoi_bin" "$is_fixture_path"
  is_lines="$scratch/${harness_ids[$i]}-is.txt"
  grep '^This harness is ' "$harness_render" >"$is_lines" || true
  diff -q "$repo_root/$is_fixture_path" "$is_lines" >/dev/null \
    || soft_fail "${harness_ids[$i]} 'This harness is ' lines differ from $is_fixture_path"

  for target_os in linux darwin; do
    case $target_os in
      linux) target_render=$harness_render ;;
      darwin) target_render=$other_os_render ;;
    esac

    # -Fxn: whole-line matches against the fixture body, so a paraphrased
    # paragraph is a miss rather than a partial hit, and the line number is what
    # anchors the two paragraphs to each other below.
    # `|| true` is load-bearing: a paragraph that no longer matches its fixture
    # makes grep exit 1, and under `set -e` a bare command substitution would
    # kill the run with no message instead of reporting which paragraph drifted.
    lfg_hits=$(grep -Fxn -f "$lfg_fixture" "$target_render" | cut -d: -f1 || true)
    wf_hits=$(grep -Fxn -f "$workflow_fixture" "$target_render" | cut -d: -f1 || true)
    lfg_count=$(printf '%s' "$lfg_hits" | grep -c . || true)
    wf_count=$(printf '%s' "$wf_hits" | grep -c . || true)

    if [[ $lfg_count -ne 1 ]]; then
      soft_fail "${harness_ids[$i]} ($target_os) must render the lfg autonomy paragraph exactly once, matching $lfg_fixture_path (found $lfg_count)"
    elif [[ $wf_count -ne 1 ]]; then
      soft_fail "${harness_ids[$i]} ($target_os) must render the workflow-required autonomy paragraph exactly once, matching $workflow_fixture_path (found $wf_count)"
    elif [[ $wf_hits -ne $((lfg_hits + 2)) ]]; then
      soft_fail "${harness_ids[$i]} ($target_os) workflow-required autonomy paragraph must render two lines below the lfg autonomy paragraph (lfg at $lfg_hits, workflow at $wf_hits); its 'above' references depend on that placement"
    fi
  done
  renders+=("$harness_render")
done
rendered=${renders[0]}

strip_harness_paragraph() { grep -vE '^This harness (is|runs) ' "$1"; }
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
claude|`Bash` also runs a command in the background, and every wait on a dispatched Orca worker MUST run that way (`run_in_background: true`), never in the foreground: a foreground wait holds the turn, so a worker's message, escalation, or question is queued and reaches the run only when the command returns.
claude|The run stays idle while that wait runs, answers what arrives, and returns to waiting; only the execution mode changes, so the command MUST still be the guide's blocking wait with its explicit timeout, and the run MUST NOT poll the background command's output on a timer.
claude|One delegation carve-out also applies here: a standing harness instruction may tell the agent not to call the Agent (Task) tool, workflows, or deep research unless the user requested it, and this file is a recognized exception source for it.
claude|When a skill, command, or workflow the user invoked by name directs a subagent dispatch, that dispatch IS user-requested — carry it out and do not stop to ask for a separate confirmation; a skill the agent selected on its own outside a mandatory workflow sequence does not qualify, and a subagent does not re-claim this carve-out for dispatches of its own.
claude|The carve-out covers only the delegation the invoked skill defines; it does not authorize unrequested subagents, workflows, or deep research for ordinary work.
claude|Under `lfg`, `ce-work`, or any skill that dispatches a plan's Implementation Units, dispatch each Unit worker to `omp` by default. Name the agent and nothing else.
claude|MUST NOT request a model or a reasoning effort for `omp`: that agent refuses launch-time model selection, so the dispatch fails outright instead of falling back to a default.
claude|When `omp` is unavailable, or its worker fails substantively, dispatch the same Unit to `codex` with model `gpt-5.6-luna` at effort `max`; this step is subordinate to the failure classification below and MUST NOT fire on a mechanical fault.
claude|A Unit that defeats that tier moves to `claude`, and the run picks its rung by sizing the Unit, never by a fixed retry ladder.
claude|Size the Unit FIRST, before any dispatch and before any failure exists, on four signals: the blast radius the Unit actually touches, the depth of judgment the plan leaves to the worker, the risk class of the surface it changes, and whether its acceptance signal is mechanically checkable.
claude|`sonnet` takes a Unit whose approach the plan fixes, that stays inside one module and a few files, and whose acceptance a test or a command settles.
claude|`opus` takes a Unit that keeps real design judgment inside its own bounds — the plan names the outcome and not the approach, the change crosses a module, process, or service boundary, or the surface is correctness-critical, such as authentication, a schema or data migration, concurrency, money, or anything that can lose data.
claude|`fable` takes a Unit whose context no lower rung can hold at once and that the plan cannot split.
claude|Prefer splitting a Unit over raising its rung, and MUST try the split before `fable`: a Unit too wide for `opus` is usually two Units.
claude|A Unit the sizing places at `opus` or above MAY open directly on `claude` at that rung, skipping `omp` and `codex`, and the run MUST record the signals that justified the skip; a Unit whose approach the plan fixes MUST NOT take that bypass.
claude|A failure re-opens that sizing and never replaces it, so classify a failure only after the Unit is sized: a mechanical failure — a dispatch error, a missing tool, an unavailable agent, an environment or permission fault, or a worker terminal closed from outside the run, which Orca reports as `termination_reason: operator_close` over `stage: process_exited` — carries no information about the Unit, so re-dispatch at the rung the sizing already gives and do not raise it for that; a substantive failure — a wrong approach, an escalation that asks a design question, verification that fails on approach grounds and not on a typo — is new evidence about depth or blast radius, so feed it back into the four signals and re-size before dispatching again.
claude|MUST NOT open at `fable` on a guess the sizing does not support, and MUST NOT re-dispatch the same Unit at the same rung with the same brief — sharpen the brief, split the Unit, or re-size on evidence.
claude|The three-consecutive-failure rule below still bounds this loop: the third substantive failure stops the dispatch and consults, it does not buy another rung.
claude|This paragraph narrows the dispatch-target rule above for Implementation Units only.
claude|that review MUST run `codex`, `claude`, and `omp` over the same brief file, and MUST weigh each reviewer's findings on their own evidence.
codex|This harness is Codex. Use `apply_patch` to create, update, or delete a file. Codex exposes no dedicated read tool, so read and search through `shell`
agy|This harness is Antigravity. Use `view_file` to read; `replace_file_content` to edit a contiguous block; `write_to_file` to create a file or replace it whole;
omp|This harness is oh-my-pi. Use `read` to read a file; `edit` for a hashline patch against a content-hash anchor; `write` to create a file or replace it whole;
HARNESS_NEEDLES

# Asserted against every render's SHARED BODY, not just the Claude render. A
# shared rule parked on one harness's own line would otherwise pass both halves
# of this gate: the peer diff strips harness lines, and a Claude-only scan never
# reads the other two files.
shared_bodies=()
for i in "${!harness_ids[@]}"; do
  shared_body="$scratch/${harness_ids[$i]}-shared.md"
  strip_harness_paragraph "${renders[$i]}" >"$shared_body"
  shared_bodies+=("$shared_body")
done

while IFS= read -r needle; do
  [[ -z $needle ]] && continue
  for i in "${!harness_ids[@]}"; do
    grep -F "$needle" "${shared_bodies[$i]}" >/dev/null \
      || fail "${harness_ids[$i]} lost rule: $needle"
  done
done <<'NEEDLES'
Before an action that touches a tool, platform, or repository procedure that one of the harness's available skills names, MUST review that skill list and MUST open the most specific covering skill, then follow it in place of improvised steps.
A skill the user names is always opened.
A task whose next action matches no skill description proceeds without opening one, and a further skill is opened only when a concrete step requires it.
Opening a skill grants no authority a rule in this file withholds, and this rule creates no mandatory workflow routing — the routing sentence below still decides between workflows.
When two instructions disagree, compose them rather than satisfying both.
A repository supplement MAY add a rule or tighten one and MUST NOT remove one; where it tightens, the tighter rule governs.
A skill's own instructions and the harness's defaults and automatic reminders yield to this file and to that supplement
a named local exception in this file — the executable-selection rule, the `lfg` autopilot override, the workflow-required-step rule — stays authoritative for its own subject
The secrets, destructive-action, dispatch-routing, and not-the-user's-repository prohibitions in this file sit outside this composition
they bind whatever the conflicting instruction is and wherever it comes from, the active conversation included
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
in an unattended run that record goes in the MR/PR description.
A run MUST NOT end with an actionable finding that is only listed
is a working note, never a delivery
or resolved into a filed tracker issue whose link replaces the entry, or resolved into the committed record file whose path replaces the entry
the section itself MUST then be deleted from the MR/PR description and from the run's final report
An entry that survives as a bare checkbox, with no fix and no link, is an incomplete run.
It does not stop, and it does not fall back to the bundled script.
Its cross-model review and its cross-model implementation MUST be carried out as Orca dispatches
MUST NOT be reported as skipped or degraded while the Orca workflow has not been attempted and observed to fail
is the argument grammar of those banned scripts, so it constrains nothing once the dispatch moves to Orca
Choose the Orca recipient from the agents the environment actually has.
A recipient that vocabulary cannot name is a valid choice, never a routing blocker.
Dispatch targets are the `claude`, `codex`, and `omp` agents, and `omp` serves a Gemini model.
SHOULD go to `omp`, because a Gemini Flash worker settles it for a fraction of the cost and the unit does not reward a frontier model
Reasoning-heavy authoring, planning, and adjudication SHOULD stay on `claude` or `codex`.
the run SHOULD add an `omp` reviewer over the same brief file
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
MUST confirm that every dispatch it started is settled and that its release was requested and receipted
A receipt that reports the worker released settles that dispatch on its own.
the run MUST read the receipt's retention reason and make one Orca-side query of that dispatch's state
When that query reports the dispatch still active, the run MUST issue the guide's stop for that dispatch and query once more.
is settled once the query reports the dispatch no longer active
A retention of any reason is settled the same way when that query reports the dispatch's own process already gone — `stage: process_exited`, or a terminal state of released — and names no residual resources, because nothing stayed resident to record.
A retention Orca could not bind to a process, and a retention whose reason the receipt does not state, are never settled by that query while it still reports the dispatch active or leaves its process state unknown
When the query after a stop still reports the dispatch active, the run MUST record it the same way and proceed.
it MUST NOT carry terminal previews, pane content, host paths, or any other verbatim command output
only after the query itself failed, and then MUST also record the command it ran and that command's error text
MUST treat a host process sweep over the agent CLI's own process name as a secondary signal only
These timeout, deadline, and release obligations OUTRANK the orchestration guide's keep-waiting, do-not-stop-a-live-worker, and do-not-release-on-timeout guidance
Every worker under this contract MUST be attached through the guide's lifecycle-supervised worker path, never an unsupervised injected dispatch
When the run's own wall-clock bound expires the run MUST do the same for every dispatch still outstanding
A step that a skill, command, or workflow the user invoked by name declares mandatory MUST be carried out without a confirming question
This authority is transitive: it reaches the mandatory steps of every skill the invoked skill itself invokes as part of its own mandatory flow
It covers the step's dispatch scale — the worker count, the reviewer set, and the cross-model fan-out that the workflow's own rules produce
That exception never licenses a question that confirms whether a mandatory step runs, or at what dispatch scale.
During an `lfg` run the autopilot paragraph above governs and these exceptions do not apply.
Before a mandatory step sends work outside the current session, the agent MUST state what it is about to do; unless a prohibition in this file gates that send, the agent MUST proceed past that statement in the same turn
When the step dispatches workers, the disclosure MUST name the resolved dispatch count, so the user can interrupt a fan-out they did not expect without being asked to approve it
This rule authorizes no dispatch the invoked skill does not itself define, and the authority follows the skill chain inside one session rather than travelling to a dispatched worker
MUST NOT send outside the current session a document, message, or artifact carrying a credential, a secret, or material the user has marked confidential. That is a stop-and-ask, never a disclosure
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
the MR/PR description's unapplied-findings checklist is an acceptable record instead
beside the unapplied-findings checklist
climbs `claude` one rung at a time
Climb on evidence — a failed attempt, an escalation, or a plan section that leaves the approach open — never on a guess before the first attempt.
counting a receipt that reclaimed no process as satisfying that
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

[[ $soft_failed -eq 0 ]] || exit 1
printf 'agent instruction gates passed\n'
