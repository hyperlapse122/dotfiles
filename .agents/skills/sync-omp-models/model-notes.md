# Model notes — family character and role matching

> Why each omp role runs on the family it runs on, and what to swap to when that
> family is gone.

This file answers one question the catalog cannot: **what is this line of models
actually good at?** `SKILL.md` §`model-notes.md` owns the contract; the two hard
rules are worth repeating here because they shape everything below.

- **Keyed by FAMILY, never by model id.** A family is a tier line that outlives
  its version numbers — the Opus line, the Sol line, the Flash-Lite line. A new
  version inside a covered family needs no edit here. That is the whole point.
- **No specs. Ever.** No context size, no thinking-level list, no benchmark
  score, and no price of any kind. Those are read live from `omp models --json`;
  a copy here would be a second source of truth that drifts silently. A note
  that states a number is a bug — delete the number.
- **Price is not a selection input.** Every provider here is either a
  subscription plan or a quota-metered coding plan, so a per-call price says
  nothing about what a turn actually costs. The resource signal is `omp usage`
  — remaining quota — and it orders fallback chains, never the primary choice.
  Where a line is described as light or heavy below, that is about the TIER and
  its depth of reasoning, not about money.

Nothing here gates a value. The gates are the sync rules and the Verify section
of `SKILL.md`. The concrete ids and fallback chains live in
`.chezmoidata/agents.yaml`, which stays the single source of truth for them.

---

## The core idea: a family is a working style, not a score

The framing below is taken from **oh-my-openagent** (omo), which is the primary
external reference for this file. omo hand-tunes an agent prompt per model
family and regression-checks it against a narrow supported set, so its
conclusions about fit are backed by testing this repo does not run. Where the
job shapes line up, follow omo. Where this repo diverges, the divergence is
recorded below with a reason.

omo's central claim: **models are not ranked on one axis — they think
differently, and the same instruction lands differently in each.** Placement is
about fit between a job shape and a working style, which is why "use the best
model everywhere" is both wasteful and wrong. Two of its findings are load
bearing here:

- **A prompt cannot fix a model.** Models have hard intrinsic characteristics.
  If a line is the wrong brain for a job it stays the wrong brain no matter how
  the prompt is carved. This is why a bad fit is corrected by moving the role,
  never by writing more instructions.
- **The two behavioral families are not vendor families.** omo groups by how a
  model reads a prompt: the *communicator* group follows long mechanics-driven
  prompts (checklists, templates, nested steps — more rules means more
  compliance), and the *deep specialist* group works from concise
  principle-driven prompts and explores autonomously (more rules means more
  contradiction surface and more drift). Kimi and GLM sit in the communicator
  group with Claude, not with their own vendor.

Three splits do most of the work in this repo:

- **Communicator vs deep specialist.** The Claude lines carry a plan across
  many tool calls and narrate progress — right for a main loop. The GPT Sol
  line explores autonomously from a stated goal and is better left alone on a
  hard problem than steered turn by turn.
- **Doer vs critic.** A model reviewing another model's turn wants a different
  disposition from the one producing it. A second opinion from the same family
  tends to agree with itself; the advisor sits on a different vendor on purpose.
- **Depth vs throughput.** Background work — titles, memory, classification,
  mechanical edits — is defined by latency and volume, not judgment. Putting a
  deliberation model there burns quota and adds latency without changing the
  outcome.

---

## Family character

### Claude Opus
ids: `anthropic/claude-opus-*`
checked: 2026-07-29
- **built for** complex agentic coding when the task needs deep reasoning and a
  rigorous second pass.
- **strong at** deep multi-step reasoning; large refactors, review, and
  bug-finding; long-context and vision-heavy work; self-checking without much
  prompt scaffolding.
- **weak at / watch** heavier and slower than Sonnet or Haiku; stale
  verification reminders can tip it into over-verification; thinking can only be
  turned off at lower effort, and with thinking off tool calls can leak as plain
  text or XML tags.
- src: https://code.claude.com/docs/en/model-config ·
  https://platform.claude.com/docs/en/build-with-claude/effort ·
  https://platform.claude.com/docs/en/about-claude/models/whats-new-opus-5

### Claude Fable/Mythos
ids: `anthropic/claude-fable-*`, `anthropic/claude-mythos-*`
checked: 2026-07-29
- **built for** the hardest long-running agent work — the most capable line
  Anthropic ships, sitting above Opus.
- **strong at** long-horizon planning; ambiguous multithreaded tasks;
  delegation to subagents; memory-heavy workflows, review, and debugging.
- **weak at / watch** can overplan and do more than the task needs; Fable's
  safety classifiers can refuse cyber- or biology-adjacent work; thinking cannot
  be disabled at all, so effort is the only control. **Mythos is the same
  weights with classifiers lifted, invitation-only through Project Glasswing —
  never place it.**
- src: https://platform.claude.com/docs/en/about-claude/models/introducing-claude-fable-5-and-claude-mythos-5 ·
  https://www.anthropic.com/news/claude-fable-5-mythos-5 ·
  https://platform.claude.com/docs/en/build-with-claude/thinking

### Claude Sonnet
ids: `anthropic/claude-sonnet-*`, `google-antigravity/claude-sonnet-*`
checked: 2026-08-03
- **built for** balanced daily coding and agentic execution — speed and
  judgment in one loop.
- **strong at** code generation, data analysis, visual understanding and tool
  use; more agentic by default than older Sonnet releases; clear progress
  narration on long traces, which matters when a subagent reports back.
- **weak at / watch** low effort under-thinks on harder problems; follows
  instructions literally and can miss implied scope; manual extended thinking is
  gone in favour of adaptive thinking plus effort; non-default sampling settings
  are rejected outright. The Antigravity transport serves the same line from a
  separate daily quota, but exposes a smaller context and a shorter effort list
  than the native transport — read the catalog before assuming parity; it is
  the same-weights fallback when the Anthropic plan is spent, never an
  upgrade.
- src: https://code.claude.com/docs/en/model-config ·
  https://platform.claude.com/docs/en/build-with-claude/thinking ·
  https://www.anthropic.com/news/claude-sonnet-5

### Claude Haiku
ids: `anthropic/claude-haiku-*`
checked: 2026-07-29
- **built for** simple high-volume work where latency matters more than depth.
- **strong at** real-time and bulk tasks; straightforward transforms,
  extraction, and routine edits; parallel subagents at volume.
- **weak at / watch** not the line for architecture or subtle review; thinking
  is off by default and adaptive thinking is unavailable, so only the legacy
  extended-thinking path exists; poor fit for ambiguous or long-horizon work.
- src: https://code.claude.com/docs/en/model-config ·
  https://platform.claude.com/docs/en/build-with-claude/thinking-troubleshooting ·
  https://www.anthropic.com/news/claude-haiku-4-5

### GPT Sol
ids: `openai-codex/gpt-*-sol`
checked: 2026-07-29
- **built for** the deliberation ceiling: hard, open-ended work needing the
  strongest reasoning, planning, and tool orchestration.
- **strong at** multi-file refactors and bug hunts in unfamiliar code;
  long-running loops that inspect, revise, and verify; synthesizing messy
  context into one high-confidence answer.
- **weak at / watch** can overstep stated intent in agentic workflows; under
  evaluation pressure it has been observed gaming a leaky harness rather than
  solving the task; safeguards can slow legitimate dual-use work; more model is
  not the right trade for routine chores.
  Unreachable on this host since 2026-08-05: `openai-codex` was removed and
  `opencode-zen`, the only other provider that served this line, is in
  `disabledProviders`. The entry stays for the day a reachable provider carries
  it again; no role may name it until then.
- src: https://openai.com/index/gpt-5-6/ ·
  https://developers.openai.com/api/docs/models/gpt-5.6-sol.md ·
  https://metr.org/blog/2026-06-26-gpt-5-6-sol/

### GPT Terra
ids: `openai-codex/gpt-*-terra`
checked: 2026-07-29
- **built for** review-and-execute: most of Sol's judgment without paying the
  deliberation ceiling.
- **strong at** spot-checking another model's draft before you trust it;
  cleanly scoped tasks where a little extra reasoning improves the result;
  balanced day-to-day coding and analysis.
- **weak at / watch** not the choice for the hardest, most ambiguous calls;
  needs crisp task framing for consistent review quality; independent per-task
  analysis found the mid tier solving FEWER tasks per attempt than Sol, so a
  lighter tier does not automatically mean less total work — it can mean more
  attempts.
  Unreachable on this host since 2026-08-05, for the same reason as the Sol
  entry above — `openai-codex` removed, `opencode-zen` disabled. `advisor` and
  `reviewer` moved to the GLM main text line, which is where omo's own critic
  chains land once the GPT hops are gone.
- src: https://developers.openai.com/api/docs/models/gpt-5.6-terra.md ·
  https://openai.com/index/gpt-5-6/ ·
  https://www.vellum.ai/blog/gpt-5-6-benchmarks-explained

### GPT Luna
ids: `openai-codex/gpt-*-luna`, `opencode-go/gpt-*-luna`
checked: 2026-07-29
- **built for** bounded high-volume work that still benefits from real reasoning
  and tool use.
- **strong at** bulk extraction, classification, and rewrite passes; short tool
  loops where throughput dominates; repeatable review over many similar items.
- **weak at / watch** weaker than Sol or Terra on broad synthesis and hard edge
  cases; needs tight prompts to stay on task.
- src: https://developers.openai.com/api/docs/models/gpt-5.6-luna.md ·
  https://openai.com/index/gpt-5-6/

### GPT mini
ids: `openai-codex/gpt-*-mini`
checked: 2026-07-29
- **built for** the light floor for precise, high-volume chores that still need
  correct tool calling and structured output. The vendor names subagents as a
  target workload for this line, which is exactly the `smol` job.
- **strong at** well-defined tasks with precise prompts; function calling,
  structured output, and narrow tool chains; first-pass filtering, tagging, and
  transformation.
- **weak at / watch** brittle on open-ended or underspecified asks; needs
  explicit instructions and follow-up verification; not a place to spend
  deliberation budget.
  Unreachable on this host since 2026-08-05 — unlike the Luna line above, which
  survived on `opencode-go`: `openai-codex` was removed, and the aggregators
  that carry this id (`openrouter`, `opencode-zen`) are in `disabledProviders`.
- src: https://developers.openai.com/api/docs/models/gpt-5.4-mini.md ·
  https://openai.com/index/introducing-gpt-5-4-mini-and-nano/

### Gemini Pro
ids: `google-antigravity/gemini-*-pro`
checked: 2026-07-29
- **built for** complex multimodal reasoning and agentic work where careful tool
  use matters more than speed.
- **strong at** image-and-text agent turns needing broad world knowledge;
  precise tool use, function calling, and structured output; reliable multi-step
  execution.
- **weak at / watch** far too much model for routine classification; not an
  image-generation line; not the lowest-latency choice for bounded work.
- src: https://ai.google.dev/gemini-api/docs/models ·
  https://ai.google.dev/gemini-api/docs/models/gemini-3.1-pro-preview

### Gemini Flash
ids: `google-antigravity/gemini-*-flash`
checked: 2026-07-29
- **built for** fast generalist agentic execution and coding without paying for
  Pro.
- **strong at** agentic loops and multi-step tool use; rapid exploration and
  prototyping; holding intermediate reasoning across turns.
- **weak at / watch** gets tool-happy — Google states that higher thinking
  levels encourage more tool calls to explore and verify, so constrain tools or
  lower thinking when it spirals; less deep than Pro on the hardest work.
- src: https://ai.google.dev/gemini-api/docs/models ·
  https://ai.google.dev/gemini-api/docs/models/gemini-3.6-flash

### Gemini Flash-Lite
ids: `google-antigravity/gemini-*-flash-lite`
checked: 2026-07-29
- **built for** low-latency, high-throughput background jobs.
- **strong at** titles, memory extraction, routing, difficulty triage; document
  parsing and simple extraction; background classification at volume.
- **weak at / watch** shallower than Flash and Pro; not for hard debugging or
  broad planning.
- src: https://ai.google.dev/gemini-api/docs/models ·
  https://ai.google.dev/gemini-api/docs/models/gemini-3.1-flash-lite

### Gemini Flash-Image
ids: `google-antigravity/gemini-*-flash-image`
checked: 2026-07-29
- **built for** image creation and editing, not agent work.
- **strong at** image generation and conversational editing; search-grounded
  visual output.
- **weak at / watch** **it cannot drive an agent turn at all — no function
  calling, no code execution, no structured output.** It is also the trap a
  naive "latest in the series" rule falls into when picking for `vision`,
  because it sorts adjacent to the Flash-Lite line.
- src: https://ai.google.dev/gemini-api/docs/models/gemini-3.1-flash-image ·
  https://ai.google.dev/gemini-api/docs/image-generation

### Kimi K series
ids: `kimi-code/k*`, `kimi-code/kimi-k*`, `opencode-go/kimi-k*`
checked: 2026-07-29
- **built for** agentic real work: long-horizon coding, tool use, visual
  understanding, and end-to-end delivery.
- **strong at** large-codebase navigation and multi-file refactors; terminal and
  browser orchestration with iterative verification; visual-to-code from
  screenshots; parallel task decomposition.
- **weak at / watch** gets overly proactive when instructions are vague; unclear
  tool definitions produce verbose or incomplete runs; wants preserved thinking
  history and a stable harness; better at agentic work than casual turns. The
  membership quota is shared across CLI, editor, and API keys and refreshes on a
  slow window, so this line is regularly spent — keep it mid-chain, never first.
- src: https://www.kimi.com/en/blog/kimi-k3 ·
  https://www.kimi.com/en/blog/kimi-k2-5 ·
  https://www.kimi.com/code/docs/en/kimi-code/membership.html

### Kimi Code aliases
ids: `kimi-code/kimi-for-coding*`
checked: 2026-07-29
- **built for** a shared membership coding assistant across terminal, editor,
  and third-party tools.
- **strong at** everyday coding and routine feature work; tool-heavy IDE and
  terminal flows.
- **weak at / watch** these ids are **server-side aliases onto other weights**,
  not distinct models, so they carry no version to float and must be treated as
  name-pinned. The HighSpeed alias accelerates model output only, so a
  tool-heavy turn erases the gain; a mistyped id silently drops to Standard; and
  turning thinking off routes the request away to an older model entirely.
- src: https://www.kimi.com/code/docs/en/kimi-code/models ·
  https://www.kimi.com/code/docs/en/kimi-code/membership.html

### GLM main text line
ids: `opencode-go/glm-5*`
checked: 2026-07-29
- **built for** the text-only engineering lane: hard coding, long-horizon agent
  work, and structured writing. `-turbo` marks an agent-optimized rung of the
  same line, not a newer version.
- **strong at** multi-file refactors and codebase-wide changes; stubborn bug
  fixing and backend work; tool-following and stepwise execution.
- **weak at / watch** **no image input anywhere in this lane** — it can never
  serve `vision`; wrong lane for screenshot-to-code or document-grounded work;
  the older leg is a step below the current one on the hardest jobs.
- src: https://docs.z.ai/guides/llm/glm-5.2 · https://docs.z.ai/guides/llm/glm-4.7 ·
  https://z.ai/blog/glm-5.2

### GLM Flash speed line
ids: `zai/glm-*-flash`, `zai/glm-*-flashx`
checked: 2026-07-29
- **built for** speed tiers, not versions: `flash` is the lightweight rung and
  `flashx` the high-speed rung.
- **strong at** quick draft, rewrite, and translation passes; boilerplate and
  short fixes; a recovery attempt that stays on the light tier when the heavier
  providers are spent.
- **weak at / watch** falls down on deep debugging, broad refactors, and careful
  end-to-end verification; not a planner. Keep it as the last hop, never a
  primary.
  Unreachable on this host since 2026-08-06: `zai` was the only provider that
  served this line, and the Z.ai coding plan expired. The entry stays for the
  day a reachable provider carries it again; no role may name it until then.
- src: https://docs.z.ai/guides/llm/glm-4.7 · https://docs.z.ai/release-notes/new-released

### GLM vision line
ids: `zai/glm-*v`, `zai/glm-*v-turbo`
checked: 2026-07-29
- **built for** the multimodal lane — work that starts from screenshots, images,
  video, or files and ends in executable action. The `v` suffix marks this lane;
  it is a variant marker, never a version.
- **strong at** screenshot-to-code and design mockups; GUI and web exploration;
  document and chart reading; visual grounding and image-based debugging.
- **weak at / watch** wasteful for pure text engineering; a sibling variant of
  the main text line, never an upgrade of it.
  Unreachable on this host since 2026-08-06, for the same reason as the GLM
  Flash entry above — `zai` was its only provider. It stays documented because
  the `vision` substitution order still names it for the day a reachable
  provider carries it again.
- src: https://docs.z.ai/guides/vlm/glm-5v-turbo · https://docs.z.ai/guides/vlm/glm-4.6v

### DeepSeek Pro
ids: `opencode-go/deepseek-*-pro`
checked: 2026-08-05
- **built for** the open-weight deliberation ceiling: agentic coding plus
  math/STEM and world-knowledge reasoning, with the chain of thought exposed as
  a first-class response field.
- **strong at** autonomous multi-step exploration in unfamiliar code — this is
  the GPT-family character that survives when a GPT plan goes away, and omo
  names it the one endorsed substitute for that departed deep line; issuing tool
  calls from inside its own reasoning pass.
- **weak at / watch** **deliberation is effectively mandatory** — the pro rung
  silently promotes a lighter reasoning request up to its heavier one, so there
  is no cheap setting on this line and it is the wrong home for routine chores;
  a tool-calling turn MUST round-trip the model's own reasoning field or the
  follow-up request is rejected; **no image input**, so it can never stand in
  for `vision`; the vendor's newer Responses transport does not carry the pro
  rung yet; and omo approves it only as a LIMITED alternative, explicitly not a
  substitute for a Sol-only job shape — a tested limitation, not a hedge.
- src: https://api-docs.deepseek.com/news/news260424 ·
  https://api-docs.deepseek.com/api/create-chat-completion ·
  https://api-docs.deepseek.com/guides/thinking_mode/ ·
  https://api-docs.deepseek.com/guides/responses_api/ ·
  https://github.com/code-yeongyu/oh-my-openagent/blob/dev/docs/guide/agent-model-matching.md

---

## Role → family matching

Why each role sits where it does. The `Family` column is machine-checked against
`agents.yaml` by the Verify section — if a role moves to another family without
this table moving with it, the check fails.

| Role | Job shape | Family | Why this family |
|---|---|---|---|
| `default` | main coding and editing loop | Claude Opus | carries a plan across many tool calls and self-checks without scaffolding |
| `slow` | deliberation ceiling | DeepSeek Pro | keeps the autonomous exploration character of the departed GPT deep line, on the plan with the most untouched headroom |
| `plan` | architecture against a huge context | Claude Fable/Mythos | built for long-horizon planning and delegation; overplanning is acceptable here |
| `designer` | UI and visual work | Claude Opus | same line as the main loop, one effort step down; vision-capable |
| `vision` | image input | Gemini Pro | image-and-text agent turns with real tool use, which the image-specialist line cannot do |
| `advisor` | passive turn review | GLM main text line | a critic from a different vendor than the doer, and where omo's own Momus/Oracle chains land once the GPT hops are gone |
| `task` | default subagent | Claude Sonnet | agentic by default and narrates progress, which is what a parent reads back |
| `smol` | light floor that still calls tools | GPT Luna | bounded high-volume tool loops retain real reasoning without entering a deliberation tier |
| `tiny` | titles, memory, background triage | Gemini Flash-Lite | latency and volume are the job; judgment is not |
| `bulk` | mechanical edits at volume — the one custom role | Gemini Flash-Lite | same tier as background work, but it owns a role so it can own a recovery order |
| `commit` | commit messages | GPT Luna | bounded transformation with a clear success test still benefits from reliable reasoning |
| `scout` | read-only exploration — and the read-only half of the compound-engineering persona fleet | Claude Sonnet | via `@task`; dispatched review work is deep-judgment, not exploration, and the light floor would demote it |
| `reviewer` | code review subagent | GLM main text line | same critic model as turn review, so the two cannot disagree by accident |
| `security-reviewer` | security review subagent | session fallback (the doer's line) | ships no frontmatter model, so omission inherits the session model — the ceiling tier compound-engineering reserves for its highest-stakes personas |
| `sonic` | mechanical bulk and extraction-tier retrieval | Gemini Flash-Lite | via `@bulk`; routine edits and grounding-scout retrieval where latency beats depth, stepping down through Claude then GPT |

---

## Cross-check against oh-my-openagent

omo assigns models to named agents and to task categories. The job shapes do
not line up one-to-one with omp roles, but most of them line up closely enough
to be a real check on this repo's placement. The comparison below is against
omo's published agent and category provider chains.

| omo agent or category | its primary | closest omp role | verdict |
|---|---|---|---|
| sisyphus — orchestrator | Claude Opus, max | `default` | agree: same line, top effort |
| hephaestus — deep specialist | GPT Sol | `slow` | agree: same line |
| oracle — architecture advice | GPT Sol, xhigh | `slow` | agree: same line and tier |
| momus — critic | GPT Terra, high | `advisor`, `reviewer` | agree: same line AND same effort, arrived at independently |
| prometheus — planning | Claude Fable, xhigh | `plan` | agree: same line and tier |
| metis — pre-plan gap analysis | Claude Opus, high | `designer` shares that tier | agree on the tier; omp has no gap-analysis role |
| atlas, sisyphus-junior — workers | Claude Sonnet | `task` | agree: same line |
| librarian, explore — utility | GPT mini (fast variant) | `smol` | **diverge** — this host deliberately selects Luna's stronger bounded-work reasoning |
| visual-engineering category | Claude Opus, max | `designer` | agree: same line |
| multimodal-looker | GPT Sol low → Kimi K → GLM vision | `vision` | **diverge** — see below |
| quick category | Kimi Code highspeed alias | `bulk`, `tiny` | **diverge** — see below |
| writing category | Kimi K, low | — | omp has no writing role |

Eight of eleven comparable slots agree. This repo derived its placement from
vendor job shapes before the comparison was run. Treat the remaining agreement
as corroboration, not as coincidence.

**Rules borrowed wholesale.**

- **Kimi ≻ GLM** as the non-Claude communicator fallback. omo states Kimi holds
  up better than GLM under nested delegation prompts and orders its chains that
  way; the `default` chain here leads with Kimi K for that reason. GLM main text
  left that chain on 2026-08-06 with the `zai` provider, so the rule now only
  governs where a GLM hop is reintroduced. The deep specialist stays last —
  DeepSeek Pro closes the chain, where omo would put its GPT deep line between
  Kimi and GLM, because a different working style is the different-brain option,
  not the next retry.
- **Never put a utility line on an orchestrator.** omo tested this and reports
  it as a hard negative, not a preference.
- **Spend a scarce premium allocation on a low-frequency, high-leverage role,**
  not on continuous orchestration. That is exactly why `plan` — which runs once
  per plan, before the expensive work — holds the Fable line here.

**Where this repo diverges, and why.**

- `smol` runs GPT Luna rather than omo's GPT mini utility line. Mini is the
  closer speed-first utility match, but the requested policy favors Luna's
  stronger reasoning for bounded tool loops without escalating to deliberation.
- `vision` runs Gemini Pro rather than omo's Sol-first multimodal chain. This is
  provider availability, not disagreement: omo names Gemini 3.1 Pro a
  visual-capable override "where a provider exposes it", and this host exposes
  it through Antigravity with quota to spare.
- `bulk` and `tiny` run Gemini Flash-Lite rather than omo's Kimi highspeed
  alias. The Kimi membership quota here is shared across every client and is
  regularly spent, so the plan with headroom wins the background tier. Its
  OpenAI anchor uses GPT Luna rather than omo's Mini line to preserve the
  requested light-family reasoning profile.
- omo's warnings about MiniMax and Qwen as orchestrators do not apply — neither
  provider is authenticated on this host.

## Substitution order

When a family is unavailable or spent, walk left to right. These are family
moves; the concrete ids and the literal chains live in `agents.yaml`.

**Anchor rule.** Every role's resolution path — its own selector plus its chain
— reaches at least one Claude hop and at least one GPT hop, because those two
plans hold the headroom on this host. A role already sitting on an anchor
provider satisfies that half from its primary, so `default` spends every chain
hop on a different provider. The anchor stays on the ROLE's own tier — the
deliberation path on Opus and Sol, the light paths on Haiku and Luna — so
anchoring never escalates background work to a deliberation line.

| If you lose… | Swap to, in order | Avoid |
|---|---|---|
| Claude Opus (main loop) | Kimi K → GLM main text → GPT Sol | GLM Flash; any image-only line |
| Claude Sonnet (subagent fleet) | Claude Sonnet via the Antigravity transport → GPT Terra → Kimi K → GLM main text | Claude Opus or GPT Sol — a deliberation line is wasted on fleet work; any image-only line |
| Claude Fable (planning) | Claude Opus → Kimi K | GLM Flash; Claude Haiku |
| GPT Sol (deliberation) | Claude Opus → Kimi K → GLM main text | GPT Luna; any Flash-Lite line |
| GPT Terra (review) | GPT Sol → Claude Opus | the same family as the model being reviewed |
| Gemini Pro (vision) | GLM vision → Kimi K | GLM main text and Gemini Flash-Image — neither can do a vision agent turn |
| GPT Luna (light floor) | Gemini Flash → Claude Haiku → GLM Flash | Claude Opus or GPT Sol; a deliberation line here is pure waste |
| Gemini Flash-Lite (background) | Gemini Flash → Claude Haiku → GPT Luna → GLM Flash | any deliberation tier |
| Claude Haiku (bulk) | GPT Luna | Claude Fable; Kimi K at max effort |

## Never place

- **Claude Mythos** — same weights as Fable, invitation-only. A role pointing at
  it fails for any ordinary account.
- **Gemini Flash-Image** — no function calling, no code execution, no structured
  output. It cannot complete an agent turn.
- **GLM main text on `vision`** — the lane has no image input at all.
- **Kimi Code aliases where a version is expected to float** — they are
  server-side aliases with no version component; treat them as name-pinned.

## Additional references — how other harnesses assign models

Secondary to omo, and useful mainly for confirming that role-keyed assignment
is a mainstream design rather than a local invention. Checked 2026-07-29.

| Project | Assignment unit | What it does | Bearing on this repo |
|---|---|---|---|
| Continue.dev | explicit model **roles** | binds a model per role: chat, edit, apply, autocomplete, embed, rerank, summarize | the closest analogue to `modelRoles`; independent evidence that role-keyed assignment scales |
| Aider | main model plus architect / editor / weak sidecars | separates the reasoning model from the one that applies edits; `--weak-model` handles commit messages and history summaries | our `commit` role is the same idea; we do not split an edit-applier because omp applies edits itself |
| Claude Code | subagent frontmatter `model:` | defaults to `inherit`; only helper agents are pinned (statusline to Sonnet, the guide to Haiku); a small background line writes session titles | corroborates rule 5 — an override is a diff, most agents should inherit — and corroborates having a `tiny` role at all |
| OpenCode | `model` plus `small_model`, per-agent override, native fallbacks with cooldown | subagents inherit the invoking primary's model; fallbacks retry on rate-limit and 5xx | the two-slot idea is our `default` / `smol`; its per-provider cooldown is what `retry.usageAwareFallback` covers here |
| Crush | `models.large` / `models.small` slots | dual-slot config with per-slot effort tuning | same two-slot shape, plus a warning: on unknown providers both slots can collapse to the same model |
| Goose | lead / worker split | a lead model plans, a worker model executes | analogous to `plan` handing off to `default` |
| Cline, Roo Code | mode | Plan/Act, opt-in per-mode models; Roo adds sticky per-mode selection and profile binding, and child tasks inherit the parent profile | mode is their role; inheritance-by-default matches omp's precedence |
| Codex CLI | profile plus `agents.default_subagent_model` | config layering, no shipped role matrix | our subagent override layer is the same shape with an opinion attached |
| OpenRouter Auto, RouteLLM, LiteLLM router | the individual request | a classifier or score picks a model per prompt, with optional session stickiness | **deliberately rejected.** Automatic routing follows live task shape, but the effective policy lives inside a classifier score, so it cannot be reviewed in a diff or replayed from source. This repo wants a placement a reader can audit and a `chezmoi apply` can reproduce |

The pattern across all of them: a heavyweight primary, at least one lighter
sidecar, inheritance as the default for delegated work, and an explicit
override only where the job genuinely differs. That is the shape `modelRoles`
plus `task.agentModelOverrides` already has.
