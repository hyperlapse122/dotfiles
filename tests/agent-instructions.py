"""Check delivered prompt bytes and independent policy boundaries across variants."""

import json
import os
import plistlib
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

CARD_KEY = "621512777E6933FEB4458FDC4945855D4F283F05"
FAKE_KEY = "0123456789ABCDEF0123456789ABCDEF01234567"
ACTION = "{{ .user.gpgKey }}"
DELIVERIES = ("claude", "codex", "omp", "antigravity")
ROUTING_HEADING = "Agent roles and routing"
CLAUDE_HEADING = "Claude Code role orchestration"
CODEX_HEADING = "Codex role orchestration"
OMP_TOOLS_HEADING = "OMP tools and Compound Engineering"
OMP_ROLE_HEADING = "OMP role orchestration"
ANTIGRAVITY_HEADING = "Antigravity harness"
HARNESS_HEADINGS = {
    "claude": [CLAUDE_HEADING],
    "codex": [CODEX_HEADING],
    "omp": [OMP_TOOLS_HEADING, OMP_ROLE_HEADING],
    "antigravity": [ANTIGRAVITY_HEADING],
}
# Antigravity truncates a rule file at 24,000 bytes.
RULE_FRONTMATTER = "---\ntrigger: always_on\n---\n\n"
RULE_LIMIT = 24000

ROLES = {
    "root": "Conversation with the user, delegation, progress",
    "scout": "Code search, grounding, evidence gathering",
    "quick": "Mechanical edits, status lookups, commit messages",
    "writing": "Documentation and prose",
    "visual": "Frontend and UI",
    "implement": "Ordinary implementation",
    "implement-high": "Feature work across several files",
    "deep": "Hard logic or debugging that evidence can settle",
    "hard-decision": "A central decision evidence cannot settle",
    "review": "CE review personas (code, doc, simplify)",
    "review-gate": "Plan review, final gate, adversarial review",
    "architect": "Architecture and plan consultation",
    "peer": "CE-required independent cross-model review",
}

# Chain cells: entries joined by " → "; T3 entries name the provider instance.
KIMI = "`omp` `synthetic/hf:moonshotai/Kimi-K3` `high` (S)"
GLM = "`omp` `synthetic/hf:zai-org/GLM-5.3` `high` (S)"
DEEPSEEK = "`omp` `synthetic/hf:deepseek-ai/DeepSeek-V4.1-Flash`"
T3_ROOTS = {
    "claude": f"`claudeAgent` `claude-opus-5-5` `medium` → {KIMI} → {GLM}",
    "codex": "`codex` `gpt-6.1-sol` `high` → `codex` `gpt-6.1-sol` `medium` Fast → `codex` `gpt-6.1-sol` `medium`",
    "omp": KIMI,
}
T3_CHAINS = {
    "scout": f"`codex` `gpt-6-luna` `high` Fast → `claudeAgent` `claude-haiku-5-5` `medium` → {DEEPSEEK} `high` (S)",
    "quick": f"`codex` `gpt-6-luna` `high` Fast → `claudeAgent` `claude-haiku-5-5` `medium` → {DEEPSEEK} `off` (S) → `omp` `synthetic/hf:zai-org/GLM-5.3-Flash` `low` (S)",
    "writing": "`antigravity` `gemini-4-argon-low` → `claudeAgent` `claude-opus-5-5` `low`",
    "visual": f"`antigravity` `gemini-4-argon-low` → `claudeAgent` `claude-fable-5-1` `max` → `claudeAgent` `claude-opus-5-5` `max` → {KIMI}",
    "implement": f"`claudeAgent` `claude-sonnet-5-5` `medium` → `grok` `grok-4.7` `xhigh` → {GLM} → `codex` `gpt-6.1-sol` `medium` → `antigravity` `gemini-3.8-flash-high`",
    "implement-high": f"`claudeAgent` `claude-opus-5-5` `medium` → {GLM} → {KIMI} → `codex` `gpt-6.1-sol` `medium` → `antigravity` `gemini-4-argon-high`",
    "deep": "`codex` `gpt-6.1-sol` `medium` → `codex` `gpt-6.1-sol` `medium` Fast → `claudeAgent` `claude-opus-5-5` `xhigh`",
    "hard-decision": "`codex` `gpt-6.1-sol` `max` → `claudeAgent` `claude-fable-5-1` `max`",
    "review": "`codex` `gpt-6.1-sol` `medium` → `codex` `gpt-6.1-sol` `high` → `claudeAgent` `claude-opus-5-5` `high`",
    "review-gate": "`codex` `gpt-6.1-sol` `max` → `claudeAgent` `claude-opus-5-5` `max`",
    "architect": f"`claudeAgent` `claude-fable-5-1` `max` → `claudeAgent` `claude-opus-5-5` `max` → {KIMI} → `codex` `gpt-6.1-sol` `xhigh`",
    "peer": "The external model and effort the owning CE skill selects",
}
SOL = "`gpt-6.1-sol`"
TERRA = "`gpt-6.1-terra`"
OMP_KIMI = "`synthetic/hf:moonshotai/Kimi-K3` `high` (S)"
OMP_GLM = "`synthetic/hf:zai-org/GLM-5.3` `high` (S)"
OMP_DEEPSEEK = "`synthetic/hf:deepseek-ai/DeepSeek-V4.1-Flash` `low` (S)"
HARNESS_CHAINS = {
    "claude": {
        "root": "`opus` `medium`",
        "scout": "`haiku` `medium`",
        "quick": "`haiku` `medium`",
        "writing": "`opus` `low`",
        "visual": "`fable` `max` → `opus` `max`",
        "implement": "`sonnet` `medium`",
        "implement-high": "`opus` `medium`",
        "deep": "`opus` `xhigh`",
        "hard-decision": "`fable` `max`",
        "review": "`opus` `high`",
        "review-gate": "`opus` `max`",
        "architect": "`fable` `max`",
        "peer": "CE selection",
    },
    "codex": {
        "root": f"{SOL} `high` → {SOL} `medium` Fast → {SOL} `medium`",
        "scout": "`gpt-6-luna` `high` Fast",
        "quick": "`gpt-6-luna` `high` Fast",
        "writing": f"{TERRA} `medium`",
        "visual": f"{TERRA} `medium`",
        "implement": f"{TERRA} `medium`",
        "implement-high": f"{SOL} `medium`",
        "deep": f"{SOL} `medium`",
        "hard-decision": f"{SOL} `max`",
        "review": f"{SOL} `medium`",
        "review-gate": f"{SOL} `max`",
        "architect": f"{SOL} `medium`",
        "peer": "CE selection",
    },
    "omp": {
        "root": OMP_KIMI,
        "scout": OMP_DEEPSEEK,
        "quick": OMP_DEEPSEEK,
        "writing": OMP_KIMI,
        "visual": OMP_KIMI,
        "implement": OMP_GLM,
        "implement-high": OMP_GLM,
        "deep": OMP_GLM,
        "hard-decision": OMP_KIMI,
        "review": OMP_GLM,
        "review-gate": OMP_KIMI,
        "architect": OMP_KIMI,
        "peer": "CE selection",
    },
}


def table(header, rows):
    return f"| Role | {header} |\n| --- | --- |\n" + "\n".join(f"| `{role}` | {cell} |" for role, cell in rows.items())


def chain_table(chains):
    return table("Chain", chains)


def t3_chains(delivery):
    root = {"root": T3_ROOTS[delivery]} if delivery in T3_ROOTS else {}
    return root | T3_CHAINS


CE_COVERAGE = """| Workflow / identity | Role and boundary |
| --- | --- |
| General fetch/status/file/symbol lookup; `ce-sweep` source-persona fetch | `quick`; unclear connector semantics `implement` |
| `ce-sweep` media analyzer | `implement` for frame/transcript interpretation |
| `ce-sweep` decisions/reconciliation; `lfg` coordination | `root`; conflicting evidence or difficult scope `hard-decision` |
| `ce-brainstorm` grounding; `ce-pov` project/precedent scouts | `scout`; brainstorm claim verifier `implement` |
| `ce-plan` repo/history/learnings/framework-docs/web/best-practices researchers | `scout` gathering, `implement` applicability/reconciliation |
| `ce-plan` spec-flow analyzer and data-integrity guardian | `deep` |
| `ce-plan` architecture strategist/complex plan author | `architect`; ordinary delegated plan author `implement` |
| Plan review gate, final readiness gate, `ce-code-review` and `ce-doc-review` adversarial lenses | `review-gate` |
| `ce-work` implementation/design-sync; PR comment resolver | `implement`; work across several files `implement-high`, frontend and UI `visual`, complex diagnosis `deep`, architecture `architect` |
| `ce-debug` investigation/root cause; `ce-optimize` attribution | `deep`; exact gathering by `quick` or `scout` does not transfer diagnosis |
| `ce-explain` work-recap/behavior-trace scouts | `scout`; complex causal tracing `deep` |
| `ce-ideate` evidence researchers/issue intelligence | `scout` retrieval, `implement` interpretation |
| `ce-ideate` generation/ceiling; `ce-bakeoff` candidates | `implement`, `architect` or `peer` according to the skill's frame and diversity contract |
| `ce-pov` verdict/synthesis; independent peer | `architect`, conflicting evidence `hard-decision`; peer `peer` |
| `ce-code-review` correctness, standards, testing, maintainability, agent-native, security, performance, API-contract, data-migration, reliability, previous-comments, frontend-races, Swift/iOS, deployment-verification personas | `review` even on small changes |
| `ce-code-review` learnings researcher; merge/validator/report leaves | `scout` retrieval, `implement` applicability; `implement`, `review` and `implement` leaves preserving all findings |
| `ce-doc-review` whole-doc, coherence, scope, feasibility, product, design, security lenses | `review`; independent peer `peer` |
| `ce-simplify-code` reuse, quality, efficiency, comment, test-value reviewers | `review` regardless of output length |
| `ce-compound` Related Docs Finder | `scout` bounded matching; overlap interpretation `implement` |
| `ce-compound` session historian, synthesis, grounding validation | `implement`; root retains classification/drafting ownership |
| `ce-compound` security sentinel, performance oracle, data-integrity guardian, pattern-recognition specialist | `deep`; research-only framework/best-practices gathering `scout` |
| `ce-compound-refresh` investigators/replacement authors | `implement`; complex behavior verification `deep`; root retains deletion/metadata decisions |
| Documentation, guides, handoffs and other prose | `writing` |
| Browser/device/prototype execution, general workers | `implement` with required modalities/tools; frontend and UI `visual`; status only `quick` |
| Commit/publication/babysitting coordination | `root`; commit messages `quick`; deterministic commands need no extra model call; diagnosis `deep` |"""

# The Antigravity ACP release T3 Code embeds; packages/t3code-release.json
# must pin the same version, so a T3 Code bump that changes it fails here.
ACP_VERSION = "1.3.0"
ANTIGRAVITY_T3_SENTENCES = [
    f"The `antigravity` model IDs are those Antigravity ACP `{ACP_VERSION}` offers, the release the pinned T3 Code embeds; each ID ends in its effort.",
    "Dispatch an `antigravity` entry by setting `target.model` only, with no effort option, and compare the returned model ID with the requested one before counting configuration as applied.",
    f"Inside T3 Code, run a Compound Engineering `antigravity` peer on the T3 `antigravity` instance by mapping the skill's bare model ID and effort to `<id>-<effort>`, such as `gemini-4-argon` with `high` to `gemini-4-argon-high`; this mapping holds for ACP `{ACP_VERSION}`.",
    "Antigravity ACP sessions, the T3 `antigravity` instance and Compound Engineering peers alike, load none of these instructions, not even a repository's `AGENTS.md`; put every rule a delegated Antigravity task needs in its prompt.",
    "When work the UI and UX section covers goes to an Antigravity task, name in its prompt the skills that section loads and the check it requires before the work is done.",
]

ROUTING_SENTENCES = [
    "A role picks a model and grants no permission to delegate: keep each skill's root ownership, selection triggers, sequencing, prompts, tools, permissions, artifact contracts, and required review and verification stages.",
    "Fill unspecified fields from the role's table entry, never implicitly from the parent.",
    "Give unlisted or new delegated work the `implement` role.",
    "Inside T3 Code, the T3 Code table below decides every delegated role in place of the harness table; outside T3 Code, the harness table decides.",
    "A `root` chain picks the model when a thread or session starts.",
    "It never moves a running session to another model.",
    "Move to the next entry when the provider is disabled, the model is not offered, the usage check skips it, its usage is exhausted, its Synthetic expiry has passed, or its launch is confirmed rejected twice.",
    "A Grok `402 Payment Required` skips the entry at once.",
    "Never start a replacement while an earlier attempt may still be live: retry an unconfirmed launch with the same request ID.",
    "Mention usage only when you pass over a chain's first entry, in one line naming why.",
    "Usage only chooses among a chain's entries: never stop work, defer a delegation, or ask the user because of usage.",
    "Run `agent-usage --json` at most once every 30 minutes and reuse that reading for every delegation in between, parallel batches included.",
    "Work that delegates no model call reads no usage.",
    "Read each entry under its usage account: `codex` under `codex`, `claudeAgent` under `claude`, `antigravity` under `gemini`, `grok` under `grok`, and `omp` under `synthetic`.",
    "The usage check skips every entry of a provider whose `skip` flag is set, and only the entries of the models listed in its `skipModels`.",
    "A `stale` or `unknown` status alone skips nothing.",
    "`codex` and `claudeAgent` entries are fast, and `antigravity`, `omp`, and `grok` entries are slow, except that a chain's first entry counts as fast.",
    "Use a slow entry only when every fast entry in the chain is skipped.",
    "Within the tier in use, take the first entry in chain order that is not ahead of pace: its provider's `aheadOfPace` flag is unset and its model is not listed in `aheadModels`.",
    "When every entry of that tier is ahead of pace, take the one with the lowest `overshootPercent`, read from its model's `aheadModels` entry when present and from its provider otherwise.",
    "When the usage check skips every entry the other reasons leave runnable, use the one with the highest `remainingPercent`, read from its model's `skipModels` entry when present and from its provider otherwise.",
    "Never revive an entry whose usage is exhausted or that was skipped for any other reason.",
    "When no entry of a chain can run, do the work in the root and say that the chain had no runnable entry.",
    "Synthetic's weekly allowance is a rolling quota: report its next regeneration time and amount in place of a reset time.",
    "Entries marked (S) are Synthetic and expire after 2026-11-18.",
    "From 2026-11-19 (local date), start no new Synthetic work; tasks already running may finish.",
    "OMP may use these entries automatically, inside and outside T3 Code.",
    "The other Synthetic models (Qwen 3.8 27B, Nemotron 3 Super 120B, GPT-OSS-120B, GLM-4.7-Flash and the `syn:*` aliases) run only on explicit request, under the same expiry.",
    "`gpt-6.1-sol` at `max` runs automatically only for `hard-decision` and `review-gate`; every other GPT `max` use and every GPT `ultra` use requires the user's explicit request for the affected work.",
    "OMP entries run at `high` at most, the highest effort T3 Code passes to OMP.",
    "A Codex entry marked Fast runs at `serviceTier` `priority`, and every other Codex entry at `default`.",
    "Never select `ultrafast`.",
    "Formatting errors, transient network failures, busy slots and missing credentials justify neither a higher effort nor another role.",
    "Set options by the names `orchestrator_capabilities` lists: `effort` for `claudeAgent`, `reasoningEffort` and `serviceTier` for `codex`, `thinking` for `omp`, and the listed effort option for `grok`.",
    "A `peer` runs the external model and effort the owning CE skill selects.",
    "Dispatch independent delegated tasks in parallel: start all of them before waiting on any, and serialize only a task that needs another task's result.",
    "Give parallel writers disjoint file scopes, and integrate any shared file in the root yourself.",
    "Inside T3 Code, run cross-model work and reviews through `delegate_task` in place of a skill's own CLI or worktree transport, in the shared checkout without a worktree.",
    "Children that write files may run in parallel there.",
    "Tell a read-only child to inspect without editing, and disclose that its read-only access was a prompt instruction, not an enforced restriction.",
] + ANTIGRAVITY_T3_SENTENCES


def routing_contract(delivery):
    return f"""- Every harness names delegated work with these roles. A role picks a model and grants no permission to delegate: keep each skill's root ownership, selection triggers, sequencing, prompts, tools, permissions, artifact contracts, and required review and verification stages.

{table("Work", ROLES)}

- Apply the user's current overrides for their stated task, recipient, fields and duration first, then the owning skill's constraints, then the role. Fill unspecified fields from the role's table entry, never implicitly from the parent.
- Give unlisted or new delegated work the `implement` role. Mixed work takes the role of its substantive part; split it only where the owning skill already permits. Root-owned work stays in the active root, and a delegated authoring assignment does not move it out.

## When to delegate

- At the start of research or triage that is likely to require several searches, source comparisons, data reconciliation, or investigation of multiple plausible causes, identify independently answerable questions and delegate useful separable investigations to subagents. Do not wait for the work to become slow or for the user to request delegation.
- Base the split on questions that can be investigated independently and whose results contribute to the answer, not on elapsed time or tool-call count. Keep simple lookups and indivisible dependent reasoning local.
- Give each child a bounded question, relevant context and sources, and an expected return containing conclusions, supporting evidence with source references, and remaining uncertainty. Use the existing role and model rules for that assignment.
- Give a `scout` child one lookup question. Name the files, symbols, or bounded line ranges to read, and the exact command when the source is a CLI. Start independent lookup questions as separate scouts in parallel.
- Route questions requiring interpretation of code impact, compatibility, or design intent to `implement` or a higher suitable role, not `scout`.
- Every research brief requires one file or bounded range per read command and smaller rereads when output is truncated. Read the named sources in full before reporting an unresolved answer, or identify what was not read and why. Distinguish "searched and not found" from "not read, with the reason".
- When a named research tool call fails, the child inspects the error and relevant tool usage or execution context, then corrects recoverable invocation or context errors and retries through that same tool within its existing authority and the owning skill's recovery rules. One failed call does not establish that the tool is unavailable.
- Preserve the brief's target host, repository, and filter constraints when correcting a command; an unsupported constraint remains unresolved rather than being dropped. Prefer per-invocation changes to arguments, working directory, and environment; recovery grants no new authority to change repository state, persistent CLI configuration, or authentication.
- Retry only when new evidence, a corrected invocation, or a changed context gives reason to expect progress; stop recovery when no justified authorized action remains or the owning workflow requires a stop or handoff.
- Report the initial error and corrected command when recovery succeeds, with secrets redacted. When returning unresolved research, report the observed error verbatim with secrets redacted, diagnostic and recovery attempts, and the remaining blocker.
- Never present a failed query as a successful empty result, substitute a capability-degraded or skip sentence for the observed error, or switch to a built-in connector or app integration the brief did not name. The root follows the owning skill's failure and recovery rules.
- Before acting on a child's "unavailable", "empty", "not confirmed", or unresolved return, the root runs one direct check of the cheapest supporting claim, such as a list call or file read. If that check contradicts the child, discard the return, investigate inline or send a narrower brief, and report the discarded result.
- While children investigate, advance complementary work instead of repeating their searches. The root integrates their results, checks conflicting evidence, and owns user communication and the final conclusion.
- This policy permits proactive delegation within existing user authorization, runtime restrictions, recipient permissions, and the invoked skill's ownership and sequencing rules. It does not override an explicit delegation prohibition or move a skill's root-owned decisions to a child.

## Compound Engineering coverage

{CE_COVERAGE}

## Model chains

- Each role maps to a chain of models, tried left to right. Inside T3 Code, the T3 Code table below decides every delegated role in place of the harness table; outside T3 Code, the harness table decides.
- A `root` chain picks the model when a thread or session starts. It never moves a running session to another model.
- Move to the next entry when the provider is disabled, the model is not offered, the usage check skips it, its usage is exhausted, its Synthetic expiry has passed, or its launch is confirmed rejected twice. A Grok `402 Payment Required` skips the entry at once.
- Never start a replacement while an earlier attempt may still be live: retry an unconfirmed launch with the same request ID. Mention usage only when you pass over a chain's first entry, in one line naming why.
- Usage only chooses among a chain's entries: never stop work, defer a delegation, or ask the user because of usage.
- Run `agent-usage --json` at most once every 30 minutes and reuse that reading for every delegation in between, parallel batches included. Work that delegates no model call reads no usage.
- Read each entry under its usage account: `codex` under `codex`, `claudeAgent` under `claude`, `antigravity` under `gemini`, `grok` under `grok`, and `omp` under `synthetic`. The usage check skips every entry of a provider whose `skip` flag is set, and only the entries of the models listed in its `skipModels`. A `stale` or `unknown` status alone skips nothing.
- `codex` and `claudeAgent` entries are fast, and `antigravity`, `omp`, and `grok` entries are slow, except that a chain's first entry counts as fast. Use a slow entry only when every fast entry in the chain is skipped.
- Within the tier in use, take the first entry in chain order that is not ahead of pace: its provider's `aheadOfPace` flag is unset and its model is not listed in `aheadModels`. When every entry of that tier is ahead of pace, take the one with the lowest `overshootPercent`, read from its model's `aheadModels` entry when present and from its provider otherwise.
- When the usage check skips every entry the other reasons leave runnable, use the one with the highest `remainingPercent`, read from its model's `skipModels` entry when present and from its provider otherwise. Never revive an entry whose usage is exhausted or that was skipped for any other reason. When no entry of a chain can run, do the work in the root and say that the chain had no runnable entry.
- Synthetic's weekly allowance is a rolling quota: report its next regeneration time and amount in place of a reset time.
- Entries marked (S) are Synthetic and expire after 2026-11-18. From 2026-11-19 (local date), start no new Synthetic work; tasks already running may finish. OMP may use these entries automatically, inside and outside T3 Code.
- The other Synthetic models (Qwen 3.8 27B, Nemotron 3 Super 120B, GPT-OSS-120B, GLM-4.7-Flash and the `syn:*` aliases) run only on explicit request, under the same expiry.
- `gpt-6.1-sol` at `max` runs automatically only for `hard-decision` and `review-gate`; every other GPT `max` use and every GPT `ultra` use requires the user's explicit request for the affected work. OMP entries run at `high` at most, the highest effort T3 Code passes to OMP.
- A Codex entry marked Fast runs at `serviceTier` `priority`, and every other Codex entry at `default`. Never select `ultrafast`.
- Run each entry at its listed effort. Formatting errors, transient network failures, busy slots and missing credentials justify neither a higher effort nor another role.
- Set options by the names `orchestrator_capabilities` lists: `effort` for `claudeAgent`, `reasoningEffort` and `serviceTier` for `codex`, `thinking` for `omp`, and the listed effort option for `grok`.
- A `peer` runs the external model and effort the owning CE skill selects.

## Parallel work and T3 Code delegation

- Dispatch independent delegated tasks in parallel: start all of them before waiting on any, and serialize only a task that needs another task's result.
- Give parallel writers disjoint file scopes, and integrate any shared file in the root yourself.
- Inside T3 Code, run cross-model work and reviews through `delegate_task` in place of a skill's own CLI or worktree transport, in the shared checkout without a worktree. Children that write files may run in parallel there.
- Tell a read-only child to inspect without editing, and disclose that its read-only access was a prompt instruction, not an enforced restriction.

## T3 Code table

{chain_table(t3_chains(delivery))}

""" + "\n".join("- " + sentence for sentence in ANTIGRAVITY_T3_SENTENCES)


CLAUDE_SENTENCES = [
    "This section applies only to the active Claude Code harness, including Claude Code-led T3 sessions.",
    "Outside T3 Code, delegate through the `Agent` tool and set its `model` and `effort` from this table; inside T3 Code, the T3 Code table decides.",
]
CLAUDE_CONTRACT = "\n".join("- " + sentence for sentence in CLAUDE_SENTENCES) + "\n\n" + chain_table(HARNESS_CHAINS["claude"])

CODEX_SENTENCES = [
    "When a skill requires interactive setup and a person can reply in this conversation, use the dedicated question tool when it is available and usable; otherwise ask the next required question in ordinary chat with the same choices, order, and consent gates.",
    "Tool absence or mode restrictions alone do not make that conversation non-interactive; this overrides a skill's tool-based non-interactive inference.",
    "After each required chat question, yield and wait for the user's actual answer before dependent work; never invent configuration, source selection, or approval, and never treat elapsed time or a preselected option as an answer.",
    "Honor explicitly non-interactive or headless invocations and unattended scheduled or piped runs; do not substitute chat for required secret entry or protected authentication and permission mechanisms.",
    "This section applies only to the active Codex harness, including Codex-led T3 sessions.",
    "Never automatically switch to separately billed API access or purchase credits when allowance is exhausted.",
    "Outside T3 Code, delegated roles use this table; inside T3 Code, the T3 Code table decides.",
    "A root-only selection does not change child roles; preserve explicit project/invocation/conversation selections and resume state at their supported precedence.",
    "Inside T3, use `delegate_task` for every delegated role, never top-level conversations or direct provider CLI workers.",
    "Compare returned provider, model and options with the request before counting configuration as applied.",
    "Explicitly set `target.model` and the provider's effort and supported tier in `target.options`.",
    "Distinguish omitted enumeration, missing descriptors, discovery failure, disabled capabilities, provider rejection and returned-selection mismatch.",
    "Never silently clamp, substitute a model outside the role's chain, invoke a CLI escape route inside T3, drop required review or claim the requested configuration ran.",
    "Queue/backpressure and launch failures must not create duplicate live work.",
    "For Codex use `reasoningEffort` and `serviceTier`: Standard=`default`, Fast=`priority`.",
    "Preserve CE's conversation-over-checkout-over-project-over-default peer precedence, recipient allowlist, prohibitions, checkout egress gate and only its permitted live opt-in exception to checkout `off`.",
    "A `peer` retains CE's selected external identity and exact prescribed effort unless the owning skill permits the user's override.",
    "Disclose permitted recipients before sending.",
    "Before launch, map the invoked skill's pre-launch failure, started failure, no-review, retry/replacement and local-lens fallback outcomes to the observed T3 states.",
    "On abandonment/deadline, cancel owned live work, retain terminal failure classification and perform the skill's scratch cleanup.",
    "Code review retains reviewer, findings, residual risks and testing gaps; document review retains reviewer, findings, residual risks and deferred questions.",
    "POV retains its settled `final: true` answer, reasoning and round contract; a non-final position does not finish the panel.",
    "Requested/returned configuration is not serving attestation: unknown actual values stay `unverified`; peer self-reports or provider labels do not establish distinct serving families.",
    "Treat child service tier as inherited from the root unless the installed client demonstrably supports independent control.",
    "In Codex-led T3, replace CE CLI launch/status/result/reap mechanics with `delegate_task`, `task_status`, task notifications and `task_cancel`.",
    "Capture scope identity and recheck before fold-in; drift requires a fresh bounded round or explicitly incomplete coverage.",
    "Retain valid attributed findings without an independence promotion when the required evidence is missing.",
    "Validate the entire terminal artifact against the invoked skill's current required fields, arrays and evidence before aggregation.",
    "Missing arrays, truncated/malformed output, missing artifacts and fluent summaries never become an empty successful review.",
    "Retain every `taskId` and a stable `clientRequestId` for retries of one dispatch.",
    "Every new review round uses a fresh delegated task and request ID with the original brief plus prior findings/responses, not a message to its backing thread.",
    "A wait timeout leaves live work running; questions, approvals, nested children and transient retries are incomplete states.",
    "Preserve surviving findings and identify uncovered lenses after partial failure.",
    "Parent tools do not authorize answering a child's reserved approval.",
    "Outside T3, establish required enforced read-only/tool restrictions before peer egress.",
    "Instructions asking a shared-checkout child not to write do not enforce read-only access.",
    "If the selected route cannot preserve a required boundary, report that pass unavailable/degraded and use only the owning skill's compatible fallback.",
    "Inside T3, the shared prompt-instructed read-only rule applies instead.",
]
CODEX_CONTRACT = """- This section applies only to the active Codex harness, including Codex-led T3 sessions. Use bounded briefs and shared evidence.
- Prefer ChatGPT-authenticated Codex for ordinary work. Never automatically switch to separately billed API access or purchase credits when allowance is exhausted.
- When a skill requires interactive setup and a person can reply in this conversation, use the dedicated question tool when it is available and usable; otherwise ask the next required question in ordinary chat with the same choices, order, and consent gates.
- Tool absence or mode restrictions alone do not make that conversation non-interactive; this overrides a skill's tool-based non-interactive inference.
- After each required chat question, yield and wait for the user's actual answer before dependent work; never invent configuration, source selection, or approval, and never treat elapsed time or a preselected option as an answer.
- Honor explicitly non-interactive or headless invocations and unattended scheduled or piped runs; do not substitute chat for required secret entry or protected authentication and permission mechanisms.

## Codex table

- Outside T3 Code, delegated roles use this table; inside T3 Code, the T3 Code table decides.

""" + chain_table(HARNESS_CHAINS["codex"]) + """

- A root-only selection does not change child roles; preserve explicit project/invocation/conversation selections and resume state at their supported precedence. Managed startup defaults are reasserted by apply, not a promise to preserve edits to owned baseline fields.

## Dispatch and compatibility

- Inside T3, use `delegate_task` for every delegated role, never top-level conversations or direct provider CLI workers. Discover the exact provider instance, model and option descriptors with `orchestrator_capabilities`; search omitted models before declaring absence. Check child/cross-provider eligibility and required modalities/tools. Explicitly set `target.model` and the provider's effort and supported tier in `target.options`. For Codex use `reasoningEffort` and `serviceTier`: Standard=`default`, Fast=`priority`. Do not extrapolate these option names or values to other providers. Compare returned provider, model and options with the request before counting configuration as applied.
- Distinguish omitted enumeration, missing descriptors, discovery failure, disabled capabilities, provider rejection and returned-selection mismatch. Bounded discovery/recovery follows the owning skill; unsupported or unverifiable selections are reported as unavailable/degraded, with its compatible fallback. Never silently clamp, substitute a model outside the role's chain, invoke a CLI escape route inside T3, drop required review or claim the requested configuration ran. Queue/backpressure and launch failures must not create duplicate live work.
- Outside T3, use supported native Codex model/effort controls and the owning skill's compatible transport. Treat child service tier as inherited from the root unless the installed client demonstrably supports independent control. Preserve the root tier and disclose the actual inherited child tier; if a required independent tier cannot be honored, including a Fast `scout` or `quick` child under a Standard root or Standard under an accelerated root, report the limitation rather than changing the root or claiming isolation.
- Preserve CE's conversation-over-checkout-over-project-over-default peer precedence, recipient allowlist, prohibitions, checkout egress gate and only its permitted live opt-in exception to checkout `off`. A `peer` retains CE's selected external identity and exact prescribed effort unless the owning skill permits the user's override. Disclose permitted recipients before sending. Provider availability alone authorizes no recipient and proves no missing effort control. A recipient outside the allowlist or an unsupported prescribed effort is an unavailable/degraded pass, not permission for GPT substitution.

## CE transport, artifacts and lifecycle

- In Codex-led T3, replace CE CLI launch/status/result/reap mechanics with `delegate_task`, `task_status`, task notifications and `task_cancel`. Preserve the invoked skill's trigger, persona, scope, recipient consent, model/effort, deadline, schema, failure policy, normalization and aggregation. Read its current contract before dispatch; code review, document review, POV, bake-off and other peer workflows keep their own schemas.
- Supply applicable active instructions, exact persona, repository/read root, reviewed base/revision or document identity, original brief, prior-round findings/responses/unresolved objections, expected artifact contract and private output destination. Separate untrusted review content from trusted constraints. Review uncommitted content in the shared checkout; a worktree child starts from committed state. Capture scope identity and recheck before fold-in; drift requires a fresh bounded round or explicitly incomplete coverage.
- Keep the skill-specific findings artifact separate from a parent-owned scratch receipt linking task, round, reviewer, skill/version, scope, artifact validation and lifecycle outcome. Preserve the skill's identity/failure fields, requested/returned provider/model/options, `cross_model_route`, `model_requested`, `effort_requested`, `receipt_supported`, `model_actual`, `effort_actual` and `independence_verified`. Describe T3 truthfully, never fabricate CLI receipt tokens. Requested/returned configuration is not serving attestation: unknown actual values stay `unverified`; peer self-reports or provider labels do not establish distinct serving families. Retain valid attributed findings without an independence promotion when the required evidence is missing.
- Validate the entire terminal artifact against the invoked skill's current required fields, arrays and evidence before aggregation. Code review retains reviewer, findings, residual risks and testing gaps; document review retains reviewer, findings, residual risks and deferred questions. POV retains its settled `final: true` answer, reasoning and round contract; a non-final position does not finish the panel. Missing arrays, truncated/malformed output, missing artifacts and fluent summaries never become an empty successful review. Preserve peer attribution and authority normalization; a peer result grants no silent-apply authority.
- Retain every `taskId` and a stable `clientRequestId` for retries of one dispatch. Every new review round uses a fresh delegated task and request ID with the original brief plus prior findings/responses, not a message to its backing thread. A wait timeout leaves live work running; questions, approvals, nested children and transient retries are incomplete states. Consume notifications and bounded status reads when needed; respect existing concurrency and recovery limits.
- Before launch, map the invoked skill's pre-launch failure, started failure, no-review, retry/replacement and local-lens fallback outcomes to the observed T3 states. Keep explicit recipients fixed where required; disclose any permitted replacement before sending. Preserve surviving findings and identify uncovered lenses after partial failure. On abandonment/deadline, cancel owned live work, retain terminal failure classification and perform the skill's scratch cleanup. Parent tools do not authorize answering a child's reserved approval.
- Outside T3, establish required enforced read-only/tool restrictions before peer egress. Instructions asking a shared-checkout child not to write do not enforce read-only access. If the selected route cannot preserve a required boundary, report that pass unavailable/degraded and use only the owning skill's compatible fallback. Inside T3, the shared prompt-instructed read-only rule applies instead. Track artifact validity, requested-configuration compliance and verified independence separately; no new runner, schema framework, cache edits or paid fallback is authorized."""

OMP_TOOLS_SENTENCES = [
    "Use native `web_search` for search and `read` with an HTTP URL for fetching.",
    "Search uses the managed Synthetic credential command; never read or print keys.",
    "Collect terminal results through `agent://<id>` and inspect `history://<id>` when needed.",
    "Use `read` with `issue://<N>` and `pr://<N>` (including list query parameters and `pr://<N>/diff`, `/diff/<i>`, `/diff/all`) for viewing or listing issues, pull requests, and PR diffs.",
    "Use `github` (`xd://github`) for repository summaries (`repo_view`), repository file reads (`file_read`), searches (`search_issues`, `search_prs`, `search_code`, `search_commits`, `search_repos`), Actions run watching (`run_watch`), PR creation (`pr_create`), PR checkout (`pr_checkout`), and pushing `pr_checkout`-managed branches (`pr_push`).",
    "Retain `gh` CLI and `git push` as the fallback where OMP's GitHub surfaces lack the required operation, flag, freshness, or safety constraint, including `gh issue create/edit/close/comment`, `gh pr comment/review/edit/merge/ready`, `gh api graphql`, `gh --attach`, explicit cross-checkout `--repo HOST/OWNER/REPO` and `--hostname HOST` qualification, repository `<kind>/short-kebab-slug` branch naming, and uncached head-SHA verification with `git push --force-with-lease=<branch>:<sha>`.",
    "Preserve existing GitLab rules (`glab` and `mr://` diffs).",
    "Synthetic and OpenRouter models establish no recognized CE host family: for an explicitly requested `ce-code-review` cross-model pass from an OMP session, keep host family `unknown` with `CROSS_MODEL_HOST_HARNESS=omp` and `CROSS_MODEL_EXPLICIT_UNKNOWN_HOST=1` on the worker's `env` prefix for that run only, and keep `independence_verified` `false`.",
    "The user permits sanctioned OMP cross-model reviews (explicitly requested unknown-host passes) through T3's ordinary delegated permissions without enforced read-only access.",
    "Tell the reviewer to inspect without editing, and report that this is an instruction rather than a technical restriction.",
]

OMP_ROLE_SENTENCES = [
    "This section applies only to the active OMP harness, including OMP-led T3 sessions.",
    "OMP model execution uses only `synthetic` and `openrouter`; `openai-codex` and `google-antigravity` are disabled.",
    "Native Codex and Antigravity remain available for sanctioned external reviews.",
    "Outside T3, delegated roles use the Synthetic models of the OMP table automatically; run `openrouter` models only when the user explicitly requests them.",
    "Inside T3 Code, the T3 Code table decides.",
    "From 2026-11-19 (local date), the Synthetic models have expired and standalone OMP has no automatic model: start no new work and ask the user which model to use.",
    "Kimi K3, GLM 5.3, and GLM 5.3 Flash accept only `low`, `high`, and `max`, and DeepSeek V4.1 Flash accepts `none` through `max`; none of them offers `medium`, so never send `medium` to them.",
    "Inside T3, use `delegate_task` with the instance, model and options the T3 Code table names, setting `target.model` and `target.options` and comparing the returned selection before counting configuration as applied.",
    "On `instanceId` `omp` the effort option is `thinking`; do not extrapolate Codex option names (`reasoningEffort`, `serviceTier`) to OMP or other providers.",
    'Outside T3, route subagents through `task`: `sonic` for `quick`, `scout` and `seance` for `scout`, `writer` for `writing`, `designer` for `visual`, `task` with `effort` `"med"` for `implement`, `implement-high` and `deep`, `reviewer` and `security-reviewer` for `review`, and `architect` for `hard-decision`, `review-gate` and `architect`.',
    "Keep `tasks[].model` reserved for `seance` consults and `modelRoles.web` as `web/synthetic`.",
    'On these three-step ladders, `task` maps `effort` `"lo"` to `low`, `"med"` to `high`, and `"hi"` to `max`, which `maxEffort` caps at `high`.',
    "Preserve CE's conversation-over-checkout-over-project-over-default peer precedence, recipient allowlist (`CROSS_MODEL_PEERS`), prohibitions, checkout egress gate, and disclosure before sending.",
    "A `peer` retains CE's selected external identity and exact prescribed effort unless the owning skill permits the user's override, and never runs on OMP.",
]

OMP_TOOLS_CONTRACT = """- Use native `web_search` for search and `read` with an HTTP URL for fetching. Search uses the managed Synthetic credential command; never read or print keys.
- Use `read history://` for the agent roster and `read history://current/full` for the current transcript. Runtime model and effort evidence comes from the protocol state or captured provider requests; configuration and model prose do not establish the effective runtime selection.
- Outside T3, native `task` runs CLI children. Read its advertised schema before dispatch: batch calls require `context` and `tasks`, with `agent` per task when selecting a non-default agent. Structured results are enabled; pass the owning workflow's `outputSchema` and collect the child's terminal `yield` rather than accepting a prose summary. Collect terminal results through `agent://<id>` and inspect `history://<id>` when needed. A started job, partial yield, cancellation, or failure is not a completed child; preserve full result artifacts and required schema fields.
- Inside T3, use the injected app-owned MCP delegation, status, and cancellation tools according to their live descriptions; do not replace app delegation with new top-level conversations.

## GitHub tools

- Use `read` with `issue://<N>` and `pr://<N>` (including list query parameters and `pr://<N>/diff`, `/diff/<i>`, `/diff/all`) for viewing or listing issues, pull requests, and PR diffs.
- Use `github` (`xd://github`) for repository summaries (`repo_view`), repository file reads (`file_read`), searches (`search_issues`, `search_prs`, `search_code`, `search_commits`, `search_repos`), Actions run watching (`run_watch`), PR creation (`pr_create`), PR checkout (`pr_checkout`), and pushing `pr_checkout`-managed branches (`pr_push`).
- Retain `gh` CLI and `git push` as the fallback where OMP's GitHub surfaces lack the required operation, flag, freshness, or safety constraint, including `gh issue create/edit/close/comment`, `gh pr comment/review/edit/merge/ready`, `gh api graphql`, `gh --attach`, explicit cross-checkout `--repo HOST/OWNER/REPO` and `--hostname HOST` qualification, repository `<kind>/short-kebab-slug` branch naming, and uncached head-SHA verification with `git push --force-with-lease=<branch>:<sha>`.
- Preserve existing GitLab rules (`glab` and `mr://` diffs).

## Cross-model review identity and permissions

- Compound Engineering skills live in the complete pinned tree under `~/.omp/agent/plugins/compound-engineering`; read referenced assets relative to that tree and retain each skill's recipient permission, tool restrictions, identity checks, result schema, and lifecycle rules.
- Synthetic and OpenRouter models establish no recognized CE host family: for an explicitly requested `ce-code-review` cross-model pass from an OMP session, keep host family `unknown` with `CROSS_MODEL_HOST_HARNESS=omp` and `CROSS_MODEL_EXPLICIT_UNKNOWN_HOST=1` on the worker's `env` prefix for that run only, and keep `independence_verified` `false`. Automatic unknown-host review remains skipped; never invent an OMP peer token, export the opt-in as a session default, substitute a recognized family for the serving model, or turn a missing, failed, or cancelled result into a successful empty review.
- Inside T3, use app-owned delegation instead of launching the CLI peer worker. The user permits sanctioned OMP cross-model reviews (explicitly requested unknown-host passes) through T3's ordinary delegated permissions without enforced read-only access. Tell the reviewer to inspect without editing, and report that this is an instruction rather than a technical restriction. This exception does not change CLI restrictions, recipient consent, or any other agent's review policy. Validate the complete terminal artifact, retain task IDs and requested/returned selection, and keep serving model/effort `unverified` without serving evidence."""

OMP_ROLE_CONTRACT = """- This section applies only to the active OMP harness, including OMP-led T3 sessions.
- OMP model execution uses only `synthetic` and `openrouter`; `openai-codex` and `google-antigravity` are disabled. Native Codex and Antigravity remain available for sanctioned external reviews.
- Outside T3, delegated roles use the Synthetic models of the OMP table automatically; run `openrouter` models only when the user explicitly requests them. Inside T3 Code, the T3 Code table decides.
- From 2026-11-19 (local date), the Synthetic models have expired and standalone OMP has no automatic model: start no new work and ask the user which model to use.

## OMP table

""" + chain_table(HARNESS_CHAINS["omp"]) + """

- Kimi K3, GLM 5.3, and GLM 5.3 Flash accept only `low`, `high`, and `max`, and DeepSeek V4.1 Flash accepts `none` through `max`; none of them offers `medium`, so never send `medium` to them.

## Dispatch and compatibility

- Inside T3, use `delegate_task` with the instance, model and options the T3 Code table names, setting `target.model` and `target.options` and comparing the returned selection before counting configuration as applied. On `instanceId` `omp` the effort option is `thinking`; do not extrapolate Codex option names (`reasoningEffort`, `serviceTier`) to OMP or other providers.
- Outside T3, route subagents through `task`: `sonic` for `quick`, `scout` and `seance` for `scout`, `writer` for `writing`, `designer` for `visual`, `task` with `effort` `"med"` for `implement`, `implement-high` and `deep`, `reviewer` and `security-reviewer` for `review`, and `architect` for `hard-decision`, `review-gate` and `architect`. Keep `tasks[].model` reserved for `seance` consults and `modelRoles.web` as `web/synthetic`. On these three-step ladders, `task` maps `effort` `"lo"` to `low`, `"med"` to `high`, and `"hi"` to `max`, which `maxEffort` caps at `high`.
- Preserve CE's conversation-over-checkout-over-project-over-default peer precedence, recipient allowlist (`CROSS_MODEL_PEERS`), prohibitions, checkout egress gate, and disclosure before sending. A `peer` retains CE's selected external identity and exact prescribed effort unless the owning skill permits the user's override, and never runs on OMP."""

ANTIGRAVITY_SENTENCES = [
    "This section applies only to the Antigravity CLI (`agy`).",
    "Antigravity ACP sessions, including the T3 `antigravity` instance and Compound Engineering peers, do not load these instructions.",
    "An `agy` session passes host family `gemini` and `CROSS_MODEL_HOST_HARNESS=antigravity` to Compound Engineering cross-model reviews, so sanctioned `claude` and `codex` peers run as different-family reviews.",
]
ANTIGRAVITY_CONTRACT = "\n".join("- " + sentence for sentence in ANTIGRAVITY_SENTENCES)

HEADINGS = [
    "Language and Locale",
    "GPG and encryption",
    "File I/O",
    "Git",
    "Pull and merge requests",
    "Markdown",
    "Korean text",
    "Tests",
    "UI and UX",
    "Review findings",
    "Browser and device verification",
    "Cross-model reviews",
]

# The installed skills the UI and UX section must route work to; the expo-*
# skills are named together.
UI_SKILLS = [
    "frontend-design",
    "web-design-guidelines",
    "design-lenses",
    "ux-writing",
    "ux-flows",
    "cli-design",
    "vercel-react-best-practices",
    "vercel-composition-patterns",
    "vercel-react-native-skills",
    "expo-*",
    "playwright-best-practices",
]

POLICIES = {
    "Language and Locale": [
        "Use the rendered preferred language as the default for conversation with the user; choose language from the language preference, never from the region.",
        "An explicit user request for another conversation language overrides this default.",
        "Follow repository and task rules for the language of saved artifacts independently of the conversation language.",
    ],
    "GPG and encryption": [
        "Stop and report only when the PIN is rejected, the prompt times out, or the card is missing.",
        "Never print decrypted values, pass them as arguments, or open decrypted files with the file tools; pipe decrypted output straight into the command that consumes it.",
        "Leave card administration and key management to the user.",
    ],
    "File I/O": [
        "Use the harness's native read, write, edit, or patch tools for routine file reads, writes, and edits when a suitable tool is available.",
        "Use shell commands or scripts such as Python and `sed` for file I/O only when the harness has no suitable native tool or the operation requires a command-line tool.",
        "The GPG and encryption rules take precedence for decrypted output: pipe it straight into the consuming command without opening decrypted files with file tools.",
        "Inside a git-tracked directory, search file names and contents with the fff MCP tools (`find_files`, `grep`, `multi_grep`) first.",
        "Use the harness's built-in search when the fff tools are unavailable or fail, or outside a git-tracked directory.",
    ],
    "Git": ["Never rename onto or push over an existing branch."],
    "Pull and merge requests": [
        "After you open or push to a pull or merge request, babysit it until it looks ready to merge, then leave the merge to the user.",
        "Babysit a draft only when asked.",
        "Confirm with `git merge-base --is-ancestor <sha> HEAD` that the forge's head is an ancestor of your local branch tip and that your checkout has no uncommitted changes.",
        "If either check fails, neither rebase nor reset; report the branch.",
        "When the commits since the base include a merge commit, compare the rebased tip's tree with the tree `git merge-tree --write-tree <base> <old-tip>` prints for the base and your pre-rebase tip before you push, and when it reports a conflict or the trees differ, return the branch to that tip with `git reset --hard <old-tip>`, push nothing, and report the branch, because a default rebase drops a change made only inside a merge commit.",
        "When signing or a hook fails during the rebase, run `git rebase --abort` and report, and never disable signing or pass `--no-verify`.",
        "When the lease is rejected, never retry with `--force`; report the branch instead.",
        "Force-push only the head branch of a pull or merge request you opened, in this or an earlier session, or whose rebase the user explicitly authorized, only with `--force-with-lease`, and never a base branch.",
    ],
    "Markdown": [
        'In text that does not render as Markdown, such as commit messages, code comments, and plain-text or config files, write a range with a dash or a word, and an approximation with a word, and never with `\\~`.',
    ],
    "Korean text": [
        "Before you write covered text, load the `humanizer`, `grammar-checker`, and `style-guide` skills, once per session.",
        "Leave text the user asks you to post as written, and verbatim quotes, unchanged.",
    ],
    "Tests": [
        "Load the `test-audit` skill before writing, changing, reviewing, or deleting a test.",
        "When `ce-code-review` or `ce-simplify-code` meets a changed test, audit it with `test-audit` and report each problem as a finding of that review.",
        "Use the skill's `CAMPAIGN.md` only when the user asks to prune a whole subsystem's tests.",
    ],
    "UI and UX": [
        "This section covers designing, building, changing, or reviewing anything a person sees or operates: screens and components, CLI flags, prompts, and output, error messages, notifications, and settings, even when the task never names UI or UX.",
        "Before such work, load the `ux-flows`, `design-lenses`, and `ux-writing` skills, plus `frontend-design` and `web-design-guidelines` for a graphical interface and `cli-design` for a command-line one.",
        "Before calling such work done, check the result against those skills and fix every problem you find.",
        "When `ce-brainstorm` or `ce-plan` handles a requirement that defines a user flow, apply `ux-flows` to design the flow and its states before anything is built.",
        "When `ce-code-review`, `ce-simplify-code`, or `ce-polish` meets a change this section covers, audit it with those skills and report each problem as a finding of that review, whoever wrote the change.",
        "The project's own design system, components, tokens, and established patterns take precedence over every skill; apply a skill's own aesthetic direction only where the project sets none.",
        "Follow `design-lenses`' exclusions: never run impeccable's commands or scripts, and never create `PRODUCT.md` or `DESIGN.md` for it.",
        "In a project that depends on TanStack packages, find their skills with `intent list` and load the matching one with `intent load <package>#<skill>` before writing code against that package; never run `intent install` unless the user asks.",
        "`test-audit` decides which tests exist and `ce-test-browser` owns browser verification; `playwright-best-practices` governs only how a Playwright test is written.",
        "Your own chat replies and reports to the user are outside this section; `ce-noslop` covers them.",
    ],
    "Review findings": [
        "Assess every finding that a review, verification, or check step of any Compound Engineering skill reports about the work the workflow produces or changes, including testing gaps and residual risks.",
        "Apply substantiated defects and requirement violations in the same change, regardless of severity, confidence labels, or which list contains them.",
        "Reject a finding when evidence shows its facts are wrong, it requires assumptions outside supported behavior, or it depends on a speculative failure chain without a credible execution path.",
        "Reject preference-only suggestions with no basis in project rules, clarity, or maintainability, and refactoring suggestions with no concrete benefit.",
        "Reject added complexity for a vanishingly unlikely edge case only when the expected harm does not justify the implementation and maintenance cost; record the failure scenario, likelihood evidence, impact, and cost.",
        "Rarity alone does not justify rejecting a credible security or data-loss defect, and a reproducer is not required when code analysis establishes the failure path.",
        "Investigate uncertain claims before deciding; lack of evidence is not proof that a defect is impossible.",
        "Assess findings yourself without asking for routine approval to reject them, and record each rejection with its evidence or concrete reason.",
        "Leave a substantiated finding unapplied when every fix would weaken a safety check, the user declined its fix, its fix awaits a user decision, or no change in this repository can fix it.",
        "A fix that would reverse a decision the user made, a brainstorm Scope Boundary or `session-settled` entry included, is asked in every run with a person present, autonomous runs included, and listed as `awaits your decision` in a run with no person present.",
        "When the user asked only for a review, report the assessed findings and ask once whether to apply all substantiated fixes.",
    ],
    "Browser and device verification": [
        "When running in T3 Code and its browser or device tools are available, prefer `preview_*` tools for browser navigation, inspection, interaction, screenshots, and recordings: start with `preview_status`, then call `preview_open` if no automation-capable preview is attached.",
        "Respect tab ownership and prefer snapshot-provided locators: read user-driven tabs without taking them over, or open an agent-owned tab (`reuseExistingTab` `false`) for interaction.",
        "Prefer `device_list`, then `device_open`, for mobile verification, follow the returned exact `agent-device` launcher and session configuration, prefer interactive snapshot refs, and use `device_screenshot` for visual inspection while keeping `xcrun simctl` and `adb` available for builds, logs, port forwarding, and unsupported capabilities.",
        "Fall back to other browser or device tools only when T3 tools are absent, explicitly unavailable, repeatedly fail as described by active T3 instructions, or the user requests another tool; never switch merely because the preview is initially closed or the first call needs corrected arguments.",
    ],
    "Cross-model reviews": [
        "When running in T3 Code, conduct cross-model reviews through T3 Code delegated child tasks (`delegate_task`) rather than separate top-level conversations or direct CLI peer workers, selecting the requested provider and model from live capabilities and preserving requested model options.",
        "Run T3 Code cross-model reviews against the current workspace without worktree isolation, and never create a worktree through T3 Code or Git solely for a review; outside T3 Code this rule does not require T3 Code, and implementation tasks may still use worktrees.",
        "Keep reviewers read-only — enforce read-only tool restrictions where `delegate_task` exposes them, and where T3 Code provides only prompt-level read-only delegation over the shared workspace (unless a harness section requires enforced restrictions), instruct the reviewer to inspect without editing and disclose in Coverage that read-only access was prompt-instructed rather than technically enforced — supply the review brief, relevant diff, and context including uncommitted workspace changes when those are the review target, and report unavailable capabilities rather than silently substituting another model or execution path.",
    ],
}

REMOVED_COMMON = re.compile(
    r"\bPi\b|\bOpenCode\b|\.t3/|"
    r"model[- ](?:routing|selection|family)|CROSS_MODEL_|"
    r"claudeAgent|claude-(?:opus|sonnet|haiku)-|gpt-[0-9]|gemini-[0-9]|"
    r"\b(?:opus|sonnet|haiku|fable)\b|"
    r"\bacpx\b|Pi over ACP|pi-readonly|thought_level|"
    r"t3_thread_|task_status|task_cancel|clientRequestId|runtimeMode",
    re.IGNORECASE,
)
REMOVED_NON_T3_SECTIONS = re.compile(
    r"\bT3\b|\bsubagents?\b|\bdelegat(?:e|ed|es|ing|ion)\b|delegate_task|cross-model",
    re.IGNORECASE,
)
T3_SCOPED_COMMON_HEADINGS = {"Browser and device verification", "Cross-model reviews"}


TEMPLATE_ACTION = re.compile(r"{{(- )?(.*?)( -)?}}", re.DOTALL)
FLAGS = {f"if .{delivery}": delivery for delivery in DELIVERIES}


def render(template, key, delivery, locale=None):
    """Independent renderer for the template subset the instructions use."""
    if delivery not in DELIVERIES:
        raise ValueError(f"unknown delivery: {delivery}")
    output, position, condition, trim = [], 0, None, False
    values = {
        ".user.gpgKey": key,
        ".locale.name": (locale or {}).get("name", "ko_KR.UTF-8"),
        ".locale.language": (locale or {}).get("language", "ko-KR"),
    }
    for match in TEMPLATE_ACTION.finditer(template):
        text = template[position:match.start()]
        if trim:
            text = text.lstrip()
        if match[1]:
            text = text.rstrip()
        active = condition in (None, delivery)
        if active:
            output.append(text)
        action = match[2].strip()
        if action in FLAGS:
            if condition is not None:
                raise ValueError("nested delivery conditional")
            condition = FLAGS[action]
        elif action == "end":
            if condition is None:
                raise ValueError("unopened end")
            condition = None
        elif action in values:
            if active:
                output.append(values[action])
        else:
            raise ValueError(f"unknown template action: {action}")
        trim, position = bool(match[3]), match.end()
    if condition is not None:
        raise ValueError("unclosed delivery conditional")
    tail = template[position:]
    output.append(tail.lstrip() if trim else tail)
    result = "".join(output)
    if "{{" in result or "}}" in result:
        raise ValueError("incomplete template action")
    return result


def sentence_once(text, sentence):
    matches = list(re.finditer(re.escape(sentence), text))
    if len(matches) != 1:
        return False
    match = matches[0]
    before, after = text[:match.start()], text[match.end():]
    return bool(
        (not before or re.search(r"(?:^|\n)\s*- $|\. $|\n$", before))
        and (not after or after[0].isspace())
    )


def expected_headings(delivery):
    return HEADINGS + [ROUTING_HEADING] + HARNESS_HEADINGS[delivery]


def subsection(body, title):
    match = re.search(rf"(?ms)^## {re.escape(title)}\n(.*?)(?=^## |\Z)", body)
    return match[1] if match else ""


def chain_rows(body):
    rows = {}
    for role, cell in re.findall(r"(?m)^\| `([a-z-]+)` \| (.*) \|$", body):
        rows[role] = None if role in rows else cell
    return rows


def chain_problems(body, expected, name):
    actual = chain_rows(body)
    return [
        f"incorrect {name} chain for `{role}`"
        for role in sorted(set(actual) | set(expected))
        if actual.get(role) != expected.get(role)
    ]


def sentence_problems(body, sentences, name):
    return [
        f"missing, repeated or negated {name} policy: {sentence}"
        for sentence in sentences
        if not sentence_once(body, sentence)
    ]


def content_problems(text, key, delivery):
    problems = []
    matches = list(re.finditer(r"^# (.+)$", text, re.MULTILINE))
    if [m[1] for m in matches] != expected_headings(delivery) or not text.startswith("# "):
        problems.append("unexpected instruction sections")
    sections = {
        match[1]: text[match.end(): matches[i + 1].start() if i + 1 < len(matches) else len(text)]
        for i, match in enumerate(matches)
    }
    for heading, sentences in POLICIES.items():
        body = sections.get(heading, "")
        for sentence in sentences:
            if not sentence_once(body, sentence):
                problems.append(f"missing, repeated or negated policy in {heading}: {sentence}")
    recipient = f"For a new SOPS setup or secret file, use the card key `{key}` as the user's recipient, plus a machine's own recipient when it must decrypt without the card."
    if sections.get("GPG and encryption", "").count("- " + recipient) != 1:
        problems.append("incorrect host recipient")
    if key == FAKE_KEY and CARD_KEY in text:
        problems.append("literal card key in fake-key instructions")
    # Store paths are opaque identifiers, not prose or policy.
    prose = re.sub(r"/nix/store/[a-z0-9]{32}-[^\s`\"]*", "", text)
    if REMOVED_COMMON.search(prose.split("# " + ROUTING_HEADING, 1)[0]):
        problems.append("removed orchestration instructions")
    for heading in HEADINGS:
        sec = re.sub(r"/nix/store/[a-z0-9]{32}-[^\s`\"]*", "", sections.get(heading, ""))
        if heading in T3_SCOPED_COMMON_HEADINGS:
            for approved in POLICIES[heading]:
                sec = sec.replace("- " + approved, "", 1)
        if REMOVED_NON_T3_SECTIONS.search(sec):
            problems.append("removed orchestration instructions")
            break

    ui = sections.get("UI and UX", "")
    if any(f"`{role}`" in ui for role in ROLES):
        problems.append("the UI and UX section names a role")
    problems += [
        f"the UI and UX section names no `{skill}`"
        for skill in UI_SKILLS
        if f"`{skill}`" not in ui
    ]

    routing = sections.get(ROUTING_HEADING, "")
    problems += sentence_problems(routing, ROUTING_SENTENCES, "routing")
    problems += chain_problems(subsection(routing, "T3 Code table"), t3_chains(delivery), "T3")
    if routing.strip() != routing_contract(delivery):
        problems.append("unapproved routing section")

    if delivery == "claude":
        body = sections.get(CLAUDE_HEADING, "")
        problems += sentence_problems(body, CLAUDE_SENTENCES, "Claude Code")
        problems += chain_problems(body, HARNESS_CHAINS["claude"], "Claude Code")
        if body.strip() != CLAUDE_CONTRACT:
            problems.append("unapproved Claude Code normative section")
    elif delivery == "codex":
        body = sections.get(CODEX_HEADING, "")
        problems += sentence_problems(body, CODEX_SENTENCES, "Codex")
        problems += chain_problems(subsection(body, "Codex table"), HARNESS_CHAINS["codex"], "Codex")
        if body.strip() != CODEX_CONTRACT:
            problems.append("unapproved Codex normative section")
    elif delivery == "omp":
        tools_body = sections.get(OMP_TOOLS_HEADING, "")
        problems += sentence_problems(tools_body, OMP_TOOLS_SENTENCES, "OMP tools")
        role_body = sections.get(OMP_ROLE_HEADING, "")
        problems += sentence_problems(role_body, OMP_ROLE_SENTENCES, "OMP role")
        problems += chain_problems(subsection(role_body, "OMP table"), HARNESS_CHAINS["omp"], "OMP")
        if tools_body.strip() != OMP_TOOLS_CONTRACT or role_body.strip() != OMP_ROLE_CONTRACT:
            problems.append("unapproved OMP normative section")
    else:
        body = sections.get(ANTIGRAVITY_HEADING, "")
        problems += sentence_problems(body, ANTIGRAVITY_SENTENCES, "Antigravity")
        if body.strip() != ANTIGRAVITY_CONTRACT:
            problems.append("unapproved Antigravity normative section")
    if any(token in text for token in ("{{", "}}", "<no value>")) or re.search(r"@\w+@", text):
        problems.append("unrendered placeholder")
    for line in text.splitlines():
        outside_code = "".join(line.split("`")[::2])
        if re.search(r"(?<!\\)~", outside_code):
            problems.append("unescaped Markdown tilde")
            break
    return problems


def read_rules(directory):
    """Join a rules directory's prefixed files back into one render."""
    try:
        names = sorted(path.name for path in directory.iterdir() if path.name.startswith("nix-config-"))
    except OSError:
        return None, ["missing delivered instructions"]
    problems = []
    if not names or names != [f"nix-config-{index:02d}.md" for index in range(1, len(names) + 1)]:
        problems.append(f"unexpected rule files: {names}")
    bodies = []
    for name in names:
        data = (directory / name).read_bytes()
        if len(data) >= RULE_LIMIT:
            problems.append(f"rule file reaches {RULE_LIMIT} bytes: {name}")
        text = data.decode("utf-8")
        if not text.startswith(RULE_FRONTMATTER + "# "):
            problems.append(f"rule file does not open with always_on frontmatter and a section: {name}")
        bodies.append(text.removeprefix(RULE_FRONTMATTER))
    return "".join(bodies), problems


def delivery_problems(path, expected, key, delivery):
    if delivery == "antigravity":
        text, problems = read_rules(path)
        if text is None:
            return problems
    else:
        try:
            text = path.read_bytes().decode("utf-8")
        except OSError:
            return ["missing delivered instructions"]
        problems = []
    problems += content_problems(text, key, delivery)
    if text != expected:
        problems.append("delivered instructions differ from independent rendering")
    return problems


def replace_token(cell, index, value):
    """Replace the index-th code span of a chain cell."""
    spans = list(re.finditer(r"`[^`]+`", cell))
    span = spans[index]
    return cell[:span.start()] + f"`{value}`" + cell[span.end():]


def assert_problem(text, delivery, problem, label=""):
    found = content_problems(text, FAKE_KEY, delivery)
    assert any(problem in item for item in found), (label or problem, found)


def assert_sentence_mutants(text, delivery, sentences):
    for sentence in sentences:
        for replacement in ("", "Do not " + sentence, sentence + " " + sentence):
            mutated = text.replace(sentence, replacement, 1)
            assert mutated != text
            assert_problem(mutated, delivery, sentence)


def assert_chain_mutants(text, delivery, chains, name, entity_index):
    """Changing any row's model or effort fails; T3 rows carry an instance first."""
    for role, cell in chains.items():
        row = f"| `{role}` | {cell} |"
        assert text.count(row) == 1, row
        spans = re.findall(r"`([^`]+)`", cell)
        if not spans:
            mutants = [cell.replace("selects", "prefers").replace("selection", "default")]
        else:
            effort = spans[entity_index + 1]
            mutants = [
                replace_token(cell, entity_index, "gpt-6-astra" if spans[entity_index] != "gpt-6-astra" else "gpt-6.1-sol"),
                replace_token(cell, entity_index + 1, "max" if effort != "max" else "low"),
            ]
        for mutant in mutants:
            assert mutant != cell
            assert_problem(text.replace(row, f"| `{role}` | {mutant} |"), delivery, f"incorrect {name} chain for `{role}`")


def insert_bullet(text, heading, bullet):
    """Append a bullet at the end of a top-level section."""
    start = text.index("# " + heading + "\n")
    following = text.find("\n# ", start + 1)
    end = len(text) if following == -1 else following
    return text[:end].rstrip("\n") + "\n- " + bullet + "\n" + text[end:]


def self_test(template):
    """Negative controls run the same boundaries as real deliveries."""
    rendered = {delivery: render(template, FAKE_KEY, delivery) for delivery in DELIVERIES}
    for delivery, text in rendered.items():
        errors = content_problems(text, FAKE_KEY, delivery)
        assert not errors, (delivery, errors)
        for other in DELIVERIES:
            if other != delivery:
                assert_problem(text, other, "unexpected instruction sections")
        assert_sentence_mutants(text, delivery, ROUTING_SENTENCES)
        assert_chain_mutants(text, delivery, t3_chains(delivery), "T3", 1)
        for other in T3_ROOTS if delivery in T3_ROOTS else ():
            if other != delivery:
                own = f"| `root` | {T3_ROOTS[delivery]} |"
                assert_problem(text.replace(own, f"| `root` | {T3_ROOTS[other]} |"), delivery, "incorrect T3 chain for `root`")
        clause = " Never revive an entry whose usage is exhausted or that was skipped for any other reason."
        assert clause in text
        assert_problem(text.replace(clause, ""), delivery, "unapproved routing section")
        assert_problem(text.replace(clause, ""), delivery, "Never revive an entry whose usage is exhausted")
        assert_problem(insert_bullet(text, ROUTING_HEADING, "Revive an entry skipped for a disabled provider when nothing else runs."), delivery, "unapproved routing section")

    expected = rendered["claude"]
    for heading, sentences in POLICIES.items():
        for sentence in sentences:
            for replacement in ("", "Do not " + sentence, sentence + " " + sentence):
                mutated = expected.replace(sentence, replacement, 1)
                assert mutated != expected
                assert_problem(mutated, "claude", f"policy in {heading}: {sentence}")
    routing_start = "# " + ROUTING_HEADING + "\n"
    assert_problem(expected.replace(routing_start, "# Pi over ACP\n\n" + routing_start, 1), "claude", "removed orchestration instructions")
    for injected in (
        "- Delegate work to a subagent.\n",
        "- Use T3 Code.\n",
        "- Use `delegate_task` for implementation.\n",
    ):
        for mutated in (
            expected.replace("# Tests\n", "# Tests\n\n" + injected, 1),
            expected.replace(routing_start, injected + "\n" + routing_start, 1),
        ):
            assert_problem(mutated, "claude", "removed orchestration instructions", injected)
    for alias in ("opus", "sonnet", "haiku", "fable"):
        for role in ("reviewers", "workers"):
            mutated = expected.replace(routing_start, f"- Run {role} on `{alias}`.\n\n" + routing_start, 1)
            assert_problem(mutated, "claude", "removed orchestration instructions")
    assert_problem(expected.replace(FAKE_KEY, CARD_KEY), "claude", "incorrect host recipient")
    assert_problem(expected + "\n@missing@\n", "claude", "unrendered placeholder")
    assert_problem(expected + "\n<no value>\n", "claude", "unrendered placeholder")
    assert_problem(expected + "\nabout ~5 minutes\n", "claude", "unescaped Markdown tilde")
    assert not content_problems(expected.replace("PIN is usually cached", "PIN is generally cached"), FAKE_KEY, "claude")
    for bad in (
        template + "{{ .unknown }}",
        template + "{{",
        template + "{{ if .claude }}",
        template.replace("{{ if .codex }}", "{{ if .claude }}{{ if .codex }}", 1),
    ):
        try:
            render(bad, FAKE_KEY, "claude")
        except ValueError:
            pass
        else:
            raise AssertionError("invalid action was accepted")
    with tempfile.TemporaryDirectory() as directory:
        path = Path(directory) / "AGENTS.md"
        assert delivery_problems(path, expected, FAKE_KEY, "claude") == ["missing delivered instructions"]
        path.write_text(expected)
        assert not delivery_problems(path, expected, FAKE_KEY, "claude")
        path.write_text(expected + "\nAn unintended appendix.\n")
        assert "delivered instructions differ from independent rendering" in delivery_problems(path, expected, FAKE_KEY, "claude")
        path.write_text(render(template, CARD_KEY, "claude"))
        assert "incorrect host recipient" in delivery_problems(path, expected, FAKE_KEY, "claude")

        rules = Path(directory) / "rules"
        sections = re.split(r"(?m)^(?=# )", rendered["antigravity"])[1:]

        def write_rules(bodies, frontmatter=RULE_FRONTMATTER):
            shutil.rmtree(rules, ignore_errors=True)
            rules.mkdir()
            for index, body in enumerate(bodies, 1):
                (rules / f"nix-config-{index:02d}.md").write_text(frontmatter + body)

        def rule_problems():
            return delivery_problems(rules, rendered["antigravity"], FAKE_KEY, "antigravity")

        assert rule_problems() == ["missing delivered instructions"]
        write_rules(sections)
        assert not rule_problems(), rule_problems()
        write_rules(["".join(sections)])
        assert any("reaches" in problem for problem in rule_problems())
        write_rules(sections, "")
        assert any("always_on" in problem for problem in rule_problems())
        write_rules([sections[0][:-1], sections[0][-1] + sections[1], *sections[2:]])
        assert any("always_on" in problem for problem in rule_problems())
        write_rules(sections + ["# Stale\n"])
        assert "delivered instructions differ from independent rendering" in rule_problems()
        write_rules(sections)
        (rules / "nix-config-02.md").rename(rules / "nix-config-99.md")
        assert any("unexpected rule files" in problem for problem in rule_problems())

    harness = {
        "claude": (CLAUDE_HEADING, CLAUDE_SENTENCES, "Claude Code", "unapproved Claude Code normative section"),
        "codex": (CODEX_HEADING, CODEX_SENTENCES, "Codex", "unapproved Codex normative section"),
        "omp": (OMP_ROLE_HEADING, OMP_TOOLS_SENTENCES + OMP_ROLE_SENTENCES, "OMP", "unapproved OMP normative section"),
        "antigravity": (ANTIGRAVITY_HEADING, ANTIGRAVITY_SENTENCES, "Antigravity", "unapproved Antigravity normative section"),
    }
    # Rules the role contract retired: each fails as an unapproved addition.
    retired = {
        "claude": ["Only CE-required peer tasks may receive a Claude effort."],
        "codex": [
            "Role titles, large context and importance do not authorize an increase, including to `xhigh`.",
            "Standard is the default except for `scout` and `quick` Luna tasks, which have standing user authorization for Fast (`priority`).",
            "Only Codex-led CE-required Claude peer tasks may receive the owning skill's exact prescribed effort.",
        ],
        "omp": [
            "Inside T3, use `delegate_task` on `instanceId` `omp` for OMP-led children and external instances for `peer` tasks.",
            "Only OMP-led CE-required Claude peer tasks may receive the owning skill's exact prescribed effort.",
        ],
        "antigravity": [],
    }
    for delivery, (heading, sentences, name, unapproved) in harness.items():
        text = rendered[delivery]
        assert_sentence_mutants(text, delivery, sentences)
        if delivery in HARNESS_CHAINS:
            assert_chain_mutants(text, delivery, HARNESS_CHAINS[delivery], name, 0)
        for contrary in retired[delivery] + [
            "Always run reviewers at max effort.",
            "Use Ultrafast without an explicit user request.",
            "Treat a no-write prompt as sufficient enforcement for a restricted peer.",
        ]:
            assert_problem(insert_bullet(text, heading, contrary), delivery, unapproved, contrary)
    omp_implement = f"| `implement` | {HARNESS_CHAINS['omp']['implement']} |"
    assert_problem(rendered["omp"].replace(omp_implement, omp_implement.replace("`high`", "`max`")), "omp", "incorrect OMP chain for `implement`")


REPOSITORY_SENTENCES = {
    "AGENTS.md": POLICIES["Review findings"],
    "CONCEPTS.md": [
        "**Review finding** — any item a review, verification, or check step of a Compound Engineering workflow reports about the work that workflow produces or changes, whatever its severity, its confidence, or the list the step files it in.",
        "Every item is assessed; substantiated defects and requirement violations are fixed in the same change.",
        "Agents may reject factually wrong claims, unsupported scenarios, preference-only suggestions, refactors without concrete benefit, and edge-case complexity whose expected benefit does not justify its cost.",
        "Rejections require evidence or a concrete reason; rarity alone does not dismiss credible security or data-loss defects, and code analysis can establish a defect without a reproducer.",
        "A substantiated finding can remain unapplied when every fix would weaken a safety check, the user declined it, a user decision is pending, or no repository change can fix it.",
        "A fix that would reverse a decision the user already made is asked about whenever a person is present, autonomous runs included, and is left unapplied as awaiting that decision only when nobody is there to ask; any other fix that needs a decision only the user can make is asked about in an interactive run, and an autonomous run applies the recommended fix and reports it.",
        "The shared instructions define the disposition tags for unapplied findings; each entry records its evidence or reason.",
    ],
}


def repository_doc_problems(text, kind):
    pattern = (
        r"(?ms)^## Commit and pull request guidelines\n(.*?)(?=^## |\Z)"
        if kind == "AGENTS.md"
        else r"(?ms)^\*\*Review finding\*\*.*?(?=\n\s*\n|\Z)"
    )
    match = re.search(pattern, text)
    body = match[0] if match else ""
    return [
        f"{kind}: missing, repeated or negated review policy: {sentence}"
        for sentence in REPOSITORY_SENTENCES[kind]
        for _ in (0,)
        if not sentence_once(body, sentence)
    ]


def check_repository_docs(agents, concepts):
    problems = []
    for kind, text in (("AGENTS.md", agents), ("CONCEPTS.md", concepts)):
        current = repository_doc_problems(text, kind)
        problems.extend(current)
        if current:
            continue
        for sentence in REPOSITORY_SENTENCES[kind]:
            for replacement in ("", "Do not " + sentence, sentence + " " + sentence):
                mutated = text.replace(sentence, replacement, 1)
                assert mutated != text
                assert any(sentence in problem for problem in repository_doc_problems(mutated, kind)), sentence
    return problems


DOC_ROOTS = {"Claude Code": "claude", "Codex": "codex", "OMP": "omp"}


def doc_section(text, heading):
    match = re.search(rf"(?ms)^{re.escape(heading)}\n(.*?)(?=^##+ |\Z)", text)
    return match[1] if match else ""


def routing_doc_problems(text):
    """Validate every current-policy table, including the comparison column."""
    comparison = doc_section(text, "## Comparison with oh-my-openagent")
    current_column = "\n".join(
        " | ".join(row.split(" | ")[:2]) + " |"
        for row in comparison.splitlines() if row.startswith("| ")
    )
    problems = []
    for name, body in (("T3", doc_section(text, "## T3 Code table")), ("comparison", current_column)):
        problems += chain_problems(body, T3_CHAINS, f"docs/agent-routing.md {name}")
        roots = {}
        for label, cell in re.findall(r"(?m)^\| `root` \(([^)]+)\) \| (.*) \|$", body):
            roots[label] = None if label in roots else cell
        for label in sorted(set(roots) | set(DOC_ROOTS)):
            if label not in DOC_ROOTS or roots.get(label) != T3_ROOTS[DOC_ROOTS[label]]:
                problems.append(f"incorrect docs/agent-routing.md {name} chain for `root` ({label})")
    for label, delivery in DOC_ROOTS.items():
        body = doc_section(text, "### " + label)
        problems += chain_problems(body, HARNESS_CHAINS[delivery], f"docs/agent-routing.md {label}")
    return problems


def check_routing_doc(text):
    problems = routing_doc_problems(text)
    if problems:
        return problems
    rows = [f"| `{role}` | {cell} |" for role, cell in T3_CHAINS.items()]
    rows += [f"| `root` ({label}) | {T3_ROOTS[delivery]} |" for label, delivery in DOC_ROOTS.items()]
    rows += [f"| `{role}` | {cell} |" for chains in HARNESS_CHAINS.values() for role, cell in chains.items()]
    for row in rows:
        assert row in text, row
        mutated = text.replace(row, row[:-2] + " → `omp` `x` `low` |")
        assert routing_doc_problems(mutated), row
    comparison = doc_section(text, "## Comparison with oh-my-openagent")
    for row in comparison.splitlines():
        if row.startswith("| `"):
            cells = row.split(" | ")
            cells[1] += " → `omp` `x` `low`"
            mutated = text.replace(row, " | ".join(cells), 1)
            assert routing_doc_problems(mutated), row
    return []


def acp_pin_problems(release):
    """The T3 Code pin must embed the ACP release the T3 Code table names."""
    pins = release.get("antigravity") or {}
    versions = sorted({str(pin.get("version")) for pin in pins.values()})
    if versions != [ACP_VERSION]:
        return [
            f"packages/t3code-release.json pins Antigravity ACP {versions or 'nothing'}, "
            f"but the T3 Code table records ACP {ACP_VERSION}; probe the new release's model IDs "
            "and update the table, the peer mapping, and docs/agent-routing.md"
        ]
    return []


def check_acp_pin(release):
    for bad in ({}, {"antigravity": {"x86_64-linux": {"version": ACP_VERSION}, "aarch64-darwin": {"version": "9.9.9"}}}):
        assert acp_pin_problems(bad), bad
    return acp_pin_problems(release)


def check_activation(template, entry):
    """Exercise the delivered activation, including a second apply of one generation."""
    assert entry["activation"], "missing instruction activation"
    bash = shutil.which("bash")
    assert bash
    with tempfile.TemporaryDirectory() as temporary:
        home = Path(temporary)
        config = home / ".config"
        config.mkdir()
        stubs = home / "bin"
        stubs.mkdir()
        defaults = stubs / "defaults"
        path_check = (
            "assert '/usr/bin' in os.environ['PATH'].split(os.pathsep)\n"
            if entry.get("requireNativePath") else ""
        )
        defaults.write_text(
            f"#!{sys.executable}\nimport os, pathlib, sys\n"
            + path_check
            + "assert sys.argv[1:] == ['export', 'NSGlobalDomain', '-']\n"
            "sys.stdout.buffer.write((pathlib.Path(os.environ['HOME']) / 'preferences.plist').read_bytes())\n"
        )
        defaults.chmod(0o755)
        env = os.environ | {
            "HOME": str(home), "XDG_CONFIG_HOME": str(config),
            "XDG_CONFIG_DIRS": str(home / "xdg-defaults"),
            "PATH": str(stubs),
            "LANG": "C", "LANGUAGE": "fr", "LC_ALL": "C",
        }
        env.pop("DRY_RUN", None)
        raw_locale = "ko_KR" if entry["kind"] == "darwin" else "ko_KR.UTF-8"

        def preferences(language):
            (config / "plasma-localerc").write_text(
                f"[Translations]\nLANGUAGE={language}\n[Formats]\nLANG={raw_locale}\n"
            )
            (home / "preferences.plist").write_bytes(plistlib.dumps({
                "AppleLocale": raw_locale, "AppleLanguages": [language, "ko-KR"],
            }))

        def apply(environment=env):
            subprocess.run([bash, "-eu", "-c", entry["activation"]], env=environment, check=True)

        def verify(language, locale=raw_locale):
            for item in entry["paths"]:
                path = home / item["target"]
                expected = render(template, entry["key"], item["delivery"], {
                    "name": locale, "language": language,
                })
                assert not path.is_symlink(), f"instruction still a symlink: {path}"
                assert not delivery_problems(path, expected, entry["key"], item["delivery"]), path

        preferences("en-US")
        sentinel = home / "old-generation-instructions"
        sentinel.write_text("old generation")
        sentinel.chmod(0o444)
        for item in entry["paths"]:
            path = home / item["target"]
            if item["delivery"] == "antigravity":
                # An earlier render's extra rule file and the user's own rule.
                path.mkdir(parents=True)
                (path / "nix-config-99.md").write_text("stale")
                (path / "own.md").write_text("user rule")
                continue
            path.parent.mkdir(parents=True, exist_ok=True)
            path.symlink_to(sentinel)
        if entry["kdeActivation"]:
            subprocess.run([bash, "-eu", "-c", entry["kdeActivation"]], env=env, check=True)
        apply()
        verify("en-US")
        assert sentinel.read_text() == "old generation", "wrote through old generation link"
        for item in entry["paths"]:
            if item["delivery"] == "antigravity":
                own = home / item["target"] / "own.md"
                assert own.is_file() and own.read_text() == "user rule", "removed a user rule"
        preferences("ko_KR.UTF-8")
        verify("en-US")  # Source changed, but no apply has happened.
        apply(env | {"DRY_RUN": "1"})
        verify("en-US")
        apply()
        verify("ko-KR")
        if entry["kind"] == "nixos":
            defaults_dir = home / "xdg-defaults"
            defaults_dir.mkdir()
            assert entry["kdeDefaults"], "missing materialized Plasma defaults"
            shutil.copyfile(entry["kdeDefaults"], defaults_dir / "plasma-localerc")
            (config / "plasma-localerc").unlink()
            apply()
            verify("ko", entry["locale"]["name"])
        if entry["kind"] == "darwin":
            for bad in (b"not a property list", plistlib.dumps([]), plistlib.dumps({})):
                (home / "preferences.plist").write_bytes(bad)
                apply()
                verify("en", "unavailable")
        if entry.get("failureTemplate"):
            def snapshot():
                return {
                    str(path): path.read_bytes()
                    for item in entry["paths"]
                    for path in [home / item["target"], *(home / item["target"]).glob("*")]
                    if path.is_file()
                }

            before = snapshot()
            preferences("en-US")
            for failure in (
                # The second delivery fails after the first rendered successfully.
                "\n{{ if .codex }}{{ .missing }}{{ end }}\n",
                # One top-level section cannot fit in a rule file.
                "\n{{ if .antigravity }}# Oversized\n\n" + "x" * RULE_LIMIT + "\n{{ end }}",
            ):
                Path(entry["failureTemplate"]).write_text(template + failure)
                result = subprocess.run(
                    [bash, "-eu", "-c", entry["activation"]], env=env,
                    stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                )
                assert result.returncode != 0, "renderer failure was swallowed"
                assert before == snapshot(), "a failed render changed delivered instructions"


def check_darwin_helper(template, helper, renderer, template_path):
    """Cross-platform native-preference parsing, with a real packaged renderer."""
    with tempfile.TemporaryDirectory() as temporary:
        template_copy = Path(temporary) / "instructions.tmpl"
        template_copy.write_text(template)
        context = Path(temporary) / "context.json"
        context.write_text(json.dumps({
            "kind": "darwin", "user": {"gpgKey": FAKE_KEY},
            "locale": {"name": "C.UTF-8", "language": "fr"},
        }))
        command = shlex.join([
            helper, "--context", str(context), "--template", str(template_copy), "--renderer", renderer,
        ]) + ' --home "$HOME"'
        entry = {
            "kind": "darwin", "key": FAKE_KEY, "activation": command, "kdeActivation": "",
            "failureTemplate": str(template_copy),
            "paths": [{"target": target, "delivery": delivery} for delivery, target in (
                ("claude", ".claude/CLAUDE.md"), ("codex", ".codex/AGENTS.md"),
                ("omp", ".omp/agent/AGENTS.md"), ("antigravity", ".gemini/config/rules"),
            )],
        }
        check_activation(template, entry)


def main():
    template = Path(sys.argv[1]).read_bytes().decode("utf-8")
    self_test(template)
    if len(sys.argv) == 2:
        return
    check_darwin_helper(template, sys.argv[5], sys.argv[6], sys.argv[1])
    entries = json.loads(Path(sys.argv[2]).read_text())
    problems = check_repository_docs(Path(sys.argv[3]).read_text(), Path(sys.argv[4]).read_text())
    problems += check_routing_doc(Path(sys.argv[7]).read_text())
    problems += check_acp_pin(json.loads(Path(sys.argv[8]).read_text()))
    for problem in problems:
        print(problem, file=sys.stderr)
    failed = bool(problems)
    expected_renderings = {}
    for entry in entries:
        key = entry["key"]
        if entry["kind"] != "linux":
            entry["requireNativePath"] = entry["kind"] == "darwin"
            check_activation(template, entry)
        for item in entry["paths"] if entry["kind"] == "linux" else []:
            path, delivery = item["path"], item["delivery"]
            variant = (key, delivery, entry["locale"]["name"], entry["locale"]["language"])
            if variant not in expected_renderings:
                expected_renderings[variant] = render(template, key, delivery, entry["locale"])
            expected = expected_renderings[variant]
            for problem in delivery_problems(Path(path), expected, key, delivery):
                print(f"{entry['name']} {path}: {problem}", file=sys.stderr)
                failed = True
        git = Path(entry["git"])
        git_text = git.read_text() if git.is_file() else ""
        if f'\tsigningKey = "{key}"' not in git_text.splitlines():
            print(f"{entry['name']}: Git does not sign with my.user.gpgKey", file=sys.stderr)
            failed = True
        if key == FAKE_KEY and CARD_KEY in git_text:
            print(f"{entry['name']}: Git names the card key instead of my.user.gpgKey", file=sys.stderr)
            failed = True
    if failed:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
