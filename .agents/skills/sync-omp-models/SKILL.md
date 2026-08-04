---
name: sync-omp-models
description: >
  Sync the omp (oh-my-pi) model policy in `.chezmoidata/agents.yaml` —
  `modelRoles`, `task.agentModelOverrides`, and `retry.fallbackChains` — to
  omp's built-in role taxonomy and bundled subagent definitions, resolved
  against the models this host can actually reach. Load this BEFORE editing any
  omp model role, subagent model override, or fallback chain, and whenever omp
  is upgraded (a new release can add or drop a role, or retune a bundled
  agent's frontmatter). Triggers: "sync omp models", "omp model roles",
  "modelRoles", "agentModelOverrides", "fallbackChains", "omp 모델 동기화",
  "omp 역할 모델". It covers the pinned upstream references (role taxonomy,
  bundled agent bindings, resolution precedence), the availability and
  capability gates that `omp models` plus `omp usage` settle on their own, the
  selection policy that decides WHICH model fills a role (series pinning,
  always-latest version floats, and the evidence ranking that keeps vendor
  marketing out of the data), the cited `model-notes.md` companion that holds
  the researched per-model characteristics, and the two traps that make a naive
  local verification either bake real secrets into a rendered script or refuse
  to run the reconcile test.
---

# Sync omp model roles

Scope: `.chezmoidata/agents.yaml`, keys `agents.omp.settings.modelRoles`,
`agents.omp.settings.task.agentModelOverrides`, and
`agents.omp.settings.retry.fallbackChains` — nothing else. Never touch
`agents.omp.auth`, the Exa keys, `theme.*`, `symbolPreset`, `setupVersion`,
`defaultThinkingLevel`, or `agents.omp.models`. Do not commit unless asked.

This is repo-wide knowledge, not a user-invoked command. `.agents/skills`
is omp's canonical native skill root (`docs/skills.md` § "Built-in skill
providers and precedence", `agents` provider with its own
`enableAgentsUser`/`enableAgentsProject` toggles), and the path is dot-prefixed
so chezmoi treats it as internal source and never deploys it.

## What upstream defines, and what it does not

oh-my-openagent ships `agent-model-requirements.ts` / `category-model-requirements.ts`,
so its sync is a faithful mirror of an upstream chain list. **omp ships no
recommended model list at all**: `modelRoles` defaults to `{}`, the doc examples
are illustrative and stale (`claude-sonnet-4-5`, `gpt-4.1-mini`), and the setup
wizard just lets you pick from whatever is available. Do not go looking for an
upstream recommendation; there is none.

What upstream *does* define, and what this skill syncs to:

- the **role taxonomy** — `packages/coding-agent/src/config/model-roles.ts`
  (`ModelRole`, `MODEL_ROLES`), echoed in `docs/models.md` § "Role aliases and
  settings" and the `modelRoles` row of `docs/settings.md`;
- the **bundled subagent → role bindings** — each bundled agent's frontmatter
  `model:` / `thinkingLevel:`;
- the **resolution precedence** — `docs/task-agent-discovery.md` § "Model and
  structured-output precedence": `task.agentModelOverrides[agent]` → **agent
  frontmatter `model`** → parent session model fallback.

Which model fills a role stays **local policy**, and its authorities are the
root `AGENTS.md` omp paragraph, the sync rules and selection policy below, the
companion `model-notes.md`, and the trailing comments in
`.chezmoidata/agents.yaml` that record each placement's rationale. This skill
enforces that policy against the live host; it never invents a new placement
rationale.

**Ignore `docs/plans/`.** The plan that first introduced these keys is
historical and is NOT an input: its requirement numbering does not track the
rules below, and its placement tables are stale by construction because the
always-latest rule keeps moving the values it froze. Reading it produces
contradictions with the live catalog, not guidance. If a rationale is worth
keeping it lives in `agents.yaml` or `model-notes.md`; a plan document never
settles a value.

## Inputs

Fetch all of these before deciding anything. `omp models --json` is dozens of
entries with full metadata, so query it with `jq` — never paste it whole.

```sh
ref="${XDG_RUNTIME_DIR:-$HOME/.cache}/agent-scratch/omp-ref"
mkdir -p "$ref"
ver="$(omp --version | cut -d/ -f2)"          # e.g. 17.1.8; release tags are v<ver>
```

1. **Role taxonomy**, pinned to the installed binary so a newer `main` cannot
   introduce a role this host does not have:

   ```sh
   curl -fsSL "https://raw.githubusercontent.com/can1357/oh-my-pi/v$ver/packages/coding-agent/src/config/model-roles.ts" -o "$ref/model-roles.ts"
   ```

   Read `ModelRole` and `MODEL_ROLES` out of it. As of v17.2.7 the built-ins are
   `default`, `smol`, `slow`, `vision`, `plan`, `designer`, `commit`, `tiny`,
   `task`, `advisor`.

2. **Bundled subagent defaults** — the authoritative per-agent bindings, read
   from the installed binary rather than the repo so they match `$ver` exactly:

   ```sh
   omp agents unpack --dir "$ref/agents" --json
   head -20 "$ref"/agents/*.md          # frontmatter: name, model, thinkingLevel
   ```

   As of v17.2.7: `designer: "@designer"`, `librarian: "@smol"` (thinkingLevel
   `minimal`), `reviewer: "@slow"`, `scout: "@smol"` (thinkingLevel `medium`),
   `security-reviewer` (no `model` field at all), `sonic: "@smol"` (thinkingLevel
   `medium`), `task: "@task"` (thinkingLevel `auto`). Re-read them; do not trust
   this list.

3. **Local catalog — the availability gate.** `omp models --json` returns only
   models under a provider omp can actually authenticate AND has not disabled,
   so catalog presence IS both the auth check and the policy check: a listed
   selector is reachable, a provider missing entirely means either
   "unauthenticated on this host" or "listed in `disabledProviders`", and
   neither means "delisted upstream". Read the declared `disabledProviders`
   before concluding anything from an absence — `openrouter` and `opencode-zen`
   are deliberately off, so their ids MUST NOT come back into the data through
   any role, override, or chain hop. Unlike the OpenCode sibling, no separate
   liveness probe is warranted — inputs 3 and 4 settle availability between
   them, and a transient provider error is exactly what `retry.fallbackChains`
   exists to absorb.

   ```sh
   omp models --json | jq -r '.models[] | "\(.selector)\tctx=\(.contextWindow)\tthink=\(.thinking // "-")\timg=\(.input | index("image") != null)"'
   omp models --json | jq -r '[.models[].provider] | unique | join(" ")'
   ```

4. **Accounts and remaining quota — the headroom gate.** A provider can be
   authenticated and still be useless right now. `omp usage` reports every
   account's limit windows and remaining capacity, which is what orders the
   fallback chains:

   ```sh
   omp usage
   ```

5. **Matching reference — oh-my-openagent (omo).** The primary EXTERNAL
   authority on which family suits which job shape. omo maintains hand-tuned
   agent prompts and regression-checks them against a narrow supported model
   set, so its pairings are backed by maintainer testing this repo does not
   run. Follow it wherever the job shapes line up, and record any deliberate
   divergence in `model-notes.md`:

   ```sh
   base=https://raw.githubusercontent.com/code-yeongyu/oh-my-openagent/dev
   curl -fsSL "$base/docs/guide/agent-model-matching.md" -o "$ref/omo-matching.md"
   curl -fsSL "$base/docs/reference/configuration.md" -o "$ref/omo-config.md"
   ```

   Read the family sections and the agent/category provider-chain tables. Its
   warnings are as load-bearing as its recommendations — an "avoid" there is a
   tested negative result, not an opinion.

6. **Declared state**, rendered the way CI renders it — see the Verify section
   for the full recipe, including the mandatory scratch `HOME`.

If any input is empty or errors, STOP and report it — never guess from memory.

## Sync rules

1. **Taxonomy.** Every `modelRoles` key is a built-in role from input 1, with
   one carve-out: a CUSTOM role is allowed when a job shape needs its own
   fallback chain, because `retry.fallbackChains` is keyed by role and there is
   no other way to give one. A custom role MUST carry a comment saying why it
   exists. `bulk` is the only one today. A stray key with no such justification
   is an error. A built-in role that is absent is a policy choice: report it,
   do not add one.
2. **Grammar.** A role value is either `provider/model-id` with an optional
   thinking suffix (`:off|minimal|low|medium|high|xhigh|max`) or a `"@role"`
   alias. Quote every `@` value in YAML.
3. **No duplicate selector.** Across `modelRoles` +
   `task.agentModelOverrides`, a full selector (id + thinking level) appears at
   most once; a second site needing an already-named model uses `"@role"`.
   Fallback-chain entries are exempt.
4. **Availability and capability fit** — check every declared selector against
   inputs 3 and 4:
   - The selector MUST appear in `omp models --json`. If its provider is listed
     for other ids, the selector itself is wrong — fix the data. If the provider
     is absent entirely it is unauthenticated: surface it and the fix (`omp`,
     then `/login <provider>`) rather than silently demoting a role primary.
   - `vision` MUST have `img=true`.
   - Any `:level` suffix MUST appear in that model's `think=` list. A suffix on
     a model with `think=-` is silently ignored by omp; treat it as an error.
   - `plan` should keep the largest context window available, since its job is
     planning against a 1M context.
   - `smol` / `tiny` / `bulk` must stay on a lighter TIER LINE than `default`
     (see `model-notes.md`); an escalation there defeats their purpose. Judge
     that by the family, never by price — price is not a selection input.
   - Never leave a role without a model. If a selector has to go, promote a
     survivor from that role's chain and flag the change loudly.
5. **Subagent overrides are a DIFF against input 2, not a restatement.**
   - Drop any override whose value equals the bundled frontmatter value — a
     no-op that only invites drift.
   - Keep an override only where local policy genuinely diverges, and make sure
     its trailing comment in `agents.yaml` and the role -> family row in
     `model-notes.md` justify that divergence.
   - Every declared agent name MUST exist in the bundled set (or in a
     repo-managed `.omp/agents` definition). A name matching nothing is dead
     data.
   - **An omitted agent does NOT fall through to the `task` role** — it falls
     through to its own frontmatter first. `scout` and `sonic` both ship
     `@smol`, so omitting them pins them to the light floor. If policy wants a
     bundled agent off its frontmatter default, that needs an explicit override;
     silence is not neutrality. This exact trap already shipped once: `scout`
     was left undeclared in the belief that omitting it avoided the light floor,
     when omitting it guaranteed it.
6. **Chains.** `retry.fallbackChains` keys are role names only — never an
   agent name, never a `provider/*` wildcard. A wildcard outranks a role chain
   by specificity and only swaps the provider while keeping the failing model
   id, which is why it is forbidden here. Every chain key MUST also be a declared
   `modelRoles` key, or `.chezmoitemplates/omp-settings-validate.tmpl` fails the
   render.
   **A light role MUST declare its own chain.** A role with no chain falls to
   `default`, which is the deliberation chain — so silence there escalates a
   background job to the heaviest models in the config. It matters twice over
   for a role whose value is a `@role` alias: omp does not document whether the
   active role for chain lookup is the referring role or its target, so an
   alias with no chain of its own can land on `default` under one reading and on
   its target's chain under the other. Declaring a chain on BOTH ends removes
   the ambiguity instead of betting on a reading — that is why `commit` and
   `tiny` each carry one even though both alias a role that already has one.
   **Anchor providers.** Every role's RESOLUTION PATH — its own selector plus
   its chain — MUST reach at least one `anthropic` hop and at least one
   `opencode-go` hop. Those are the two plans with real headroom on this host
   (`opencode-go` replaced `openai-codex` in this rule when that provider was
   removed from the host on 2026-08-05; it is the plan that now carries the
   `gpt-5.6-luna` id, Kimi K3, GLM 5.2, and DeepSeek Pro),
   so a path that reaches neither can strand its role once the plan-served
   providers are spent. A role whose own selector already sits on an anchor
   provider satisfies that half from its primary, which frees its chain to spend
   every hop on a different provider. Anchor on the role's OWN tier — the
   deliberation path anchors on Opus and the opencode-go ceiling, the light
   paths on Haiku and Luna
   — because anchoring must never escalate background work to a deliberation
   line. The Verify section enforces this.
7. **Provider spread and quota order.** After any change, the coding loop,
   deliberation, vision, and mechanical-bulk job shapes must still resolve to
   distinct providers, so one exhausted plan is not a full stop. Read `omp
   usage` for which plan is near its wall, and order each chain so its first
   hop sits on a different provider from the role it backs. Quota exhaustion is
   a chain-ORDERING input, never a removal: a spent plan still belongs in the
   data and recovers on its reset window.
8. **No credentials.** A declared settings value must never contain `op://` —
   the provisioner passes values to `omp config set` as process arguments.
   Credentials belong in `agents.omp.auth.env`.
9. **Comments are part of the data.** The omp block in `agents.yaml` carries the
   rationale for each placement. When a value changes, update its trailing
   comment and the surrounding block comment in the same edit; a stale
   justification is worse than none.

## Model selection policy

The rules above decide what is LEGAL. This section decides what is CHOSEN.

### 1. Roles are the unit of choice, never agents

Pick a model for a role; bundled agents reach it through their `@role`
frontmatter or an override alias. Choosing per agent reintroduces exactly the
duplication rule 3 forbids and makes a retune an N-site edit.

### 2. A role's current value declares its series

There is no separate series table to maintain: parse the series out of the
value already in the file as `(provider, family, tier, variant-suffix set)`.
**Only the numeric version component may move.** `claude-opus-4-8` →
`claude-opus-5` is a version move. Everything else — crossing family
(`opus`→`sonnet`), tier (`pro`→`flash`), provider, or variant suffix — is a
policy change that needs a human decision, recorded in the value's comment.
The variant set explicitly includes a trailing `-YYYYMMDD` date: a dated id is
a PIN of the same weights, metric-identical to its floating name, so it would
otherwise sail through the dominance test in rule 3 and silently freeze the
role on one snapshot.

Version grammars differ per provider — `claude-opus-5`, `claude-sonnet-4-6`,
`gpt-5.6-sol`, `gemini-3.1-flash-lite`, `glm-5.2`, `k3`. Parse per provider.
Where the grammar is ambiguous (a bare name with no separable version, such as
`kimi-for-coding-highspeed`), treat the value as NAME-PINNED: it never floats,
and any change to it is reported as a proposal.

### 3. Always take the latest version in the series

Within a series, a role runs the **highest version the catalog offers**. There
is no capability gate on the move itself: a newer version inside the same tier
line is the vendor's own replacement for it, and sitting on an older one only
accumulates drift.

What this rule does not do is invent a move. Every guard in rule 2 still binds
— the candidate must share provider, family, tier, and variant set, with only
the numeric component higher, and a dated `-YYYYMMDD` id is never a candidate.
Those guards are what make "latest" well defined; without them a
highest-number rule wrecks real ids in this catalog:

| Naive pick | Why rule 2 rejects it |
|---|---|
| `gemini-3.1-pro` → `gemini-3.6-flash` | different tier; the `pro` line has no 3.6 |
| `gemini-3.1-flash-lite` → `gemini-3.1-flash-image` | image-output specialist, no tool calling |
| `kimi-code/k3` → `k3-256k` | a context-capped variant, not a newer version |
| `zai/glm-5.2` → `glm-5v-turbo` | `v` is a vision variant, `turbo` a speed variant |
| `claude-haiku-4-5` → `claude-haiku-4-5-20251001` | dated pin of the same weights |
| `claude-opus-5` → `claude-opus-4-8` | identical on every reported axis; only the version orders them |

When a latest-version move regresses something the catalog reports — narrower
thinking range, smaller context, lost modality — **apply it and name the
regression in the report**. That is what "always latest" costs, and the reader
decides whether to pin.

One case still blocks: a regression that breaks the role's hard requirement in
rule 4 — `vision` losing image input, or a declared `:level` the new version
does not support. Shipping that would leave a silently ignored setting, so fix
the suffix or raise it as a proposal instead.

### 4. Evidence ranking — the data may only rest on the top of this list

**Price is never an input.** Every provider here is a subscription or
quota-metered coding plan, so a per-call price says nothing about what a turn
consumes. Do not compare prices, do not record them, and do not let a cheaper
tier win an argument. The resource signal is remaining quota.

1. **`omp models --json`** — context, thinking levels, modalities. The only
   source allowed to GATE a value. Machine-checkable and re-derivable.
2. **`omp usage`** — the resource signal: which plan has headroom right now.
   It orders fallback chains; it never picks the primary. Its blind spot is
   that it reports account windows, not per-model quota weight, so two models
   on one plan cannot be ranked by consumption from here — that is what
   `omp bench` and the family notes are for.
3. **`omp bench <selector>... --runs N --json`** — first-party, local,
   reproducible time-to-first-token and tokens/s. This is the right evidence
   for `smol` / `tiny` / `sonic`, where latency IS the job and no document can
   tell you the truth for this account and region.
4. **oh-my-openagent's matching research** (input 5) — the strongest evidence
   available for FIT, as opposed to capability. omo pairs hand-tuned agent
   prompts with a narrow supported model set and regression-checks them, so its
   agent and category chains encode tested behavior, not marketing. Its
   negative results carry the same weight: a model it names as unsuitable for
   orchestration has been tried and rejected. Follow it where the job shapes
   line up; where this repo diverges, the divergence is recorded in
   `model-notes.md` with the reason.
5. **Vendor documentation via `web_search`** — capability character: what a
   tier line is BUILT FOR, what work it is genuinely good at, where it fails,
   and what access restrictions apply. It ranks LAST because it describes a
   model in isolation and is not machine-checkable: it may inform a choice,
   never gate a value. Every claim lands in `model-notes.md` beside a vendor
   URL and a check date, never loose in a report or a code comment. Official
   docs and launch posts are primary; independent technical write-ups
   corroborate; leaderboards and launch marketing never stand alone. Research
   the FAMILY, never the id, and never copy a spec out of a doc — see the next
   section for why both of those are hard rules rather than style.

### 5. An unfamiliar id is parked, not adopted

When the catalog gains an id no role names, report it and, if consulted, its
cited family description — then either propose a placement with
the job shape it serves, or park it. Silence in the data is a decision; make it
an explicit one in the report.

## `model-notes.md` — the capability-character file

`skill://sync-omp-models/model-notes.md` is the durable companion to this
procedure. It answers one question the catalog cannot: **what is this line of
models actually good at?**

Its contract is two hard rules and two soft ones.

**Hard rule 1 — entries are keyed by FAMILY, never by model id.** A family is
a tier line that outlives its version numbers: the Opus line, the Sonnet line,
the Sol line, the Flash-Lite line. Ids are interchangeable members. This is
what makes the file cheap to own — `claude-opus-5` superseding `claude-opus-4-8`
changes nothing here, because the Opus line is still built for the same job.
An id-keyed file would need an edit on every vendor release and would rot
between them.

**Hard rule 2 — no specs. Ever.** No context window, no max output, no price,
no thinking-level list, no latency figure, no benchmark score. Every one of
those is read live from `omp models --json`, and a copy here is a second
source of truth that silently drifts. It also drifts in a way that is hard to
notice, because a vendor doc is not wrong — it is just describing a different
transport: OpenAI documents the mini line at a 400,000-token context while the
`openai-codex` transport exposed 272,000 (a transport this host no longer
carries — the trap outlives it). Both are true; only the catalog is
true HERE. Recording no number at all removes the whole failure mode. A note
that states a number is a bug: delete the number.

What an entry may contain: what the line is built for, concrete job shapes it
is strong at, concrete things it is weak at or unreliable at, behavioral
caveats (mandatory thinking, alias traps, access gating, a tendency to
over-explore), and sources.

- **Every claim carries a citation.** An uncited claim is deleted, not kept.
- **It never gates a value.** It informs the choice; the gates stay rules 1–9
  and the Verify section.

Refresh an entry when:

1. The catalog exposes an id whose FAMILY the file does not cover. A new
   version inside a covered family needs no edit — that is the point.
2. Its `checked:` date is older than ~90 days and a role names that family.
3. A vendor repositions a line, or ships a new tier line beside it.

Procedure: `web_search` the vendor docs for that FAMILY, rewrite that entry
only, update its `checked:` date, and leave every other entry byte-identical.
Never bulk-regenerate the file — a wholesale rewrite discards the judgment
recorded in the `weak at` lines, which is the most expensive content in it.

## Verify before finishing (required)

Two traps make a naive local run wrong, so use this recipe verbatim:

- **`HOME` MUST point at a scratch dir.** `secrets-bundle.tmpl` keys the GPG
  cache path on `<homeDir>/.config/chezmoi/gpg-cache-ready`, which exists on
  this host. With the real `HOME`, `chezmoi execute-template` decrypts the
  committed bundle and bakes **real API keys** into the rendered auth script —
  and the reconcile test then fails on its `dummy-secret` assertion. A scratch
  `HOME` has no marker, so the shim falls back to live `op` and the stub
  answers. CI gets this for free because the marker never exists there.
- **`.ci/test-omp-agent-reconcile.sh` takes seven rendered artifacts**, matching
  `.github/workflows/ci.yml` `omp-agent-integration`. Render both OS-specific
  script halves plus the bundled haptic package, or the test refuses to run.

```sh
set -euo pipefail
scratch="${XDG_RUNTIME_DIR:-$HOME/.cache}/agent-scratch/omp-sync"
mkdir -p "$scratch/bin" "$scratch/target" "$scratch/home"; : > "$scratch/empty.toml"
# The stub must answer per-reference secrets: the reconcile test asserts
# distinct OPENROUTER/OPENCODE values, so a flat dummy-secret stub fails step 3.
cat > "$scratch/bin/op" <<'OPSTUB'
#!/usr/bin/env bash
case "$*" in
  *"op://Private/OpenRouter/API Key"*) printf openrouter-test-secret ;;
  *"op://Private/Opencode/API Key"*) printf opencode-test-secret ;;
  whoami) printf dummy@example.invalid ;;
  *) printf dummy-secret ;;
esac
OPSTUB
chmod 700 "$scratch/bin/op"
render() {
  env HOME="$scratch/home" PATH="$scratch/bin:$PATH" chezmoi \
    --config "$scratch/empty.toml" --source "$PWD" --destination "$scratch/target" \
    "$@" execute-template
}

# 1. Render every artifact. The settings render is also the validator: a dangling
#    @alias, an orphan chain key, a control char, or a parent-namespace collision
#    fails here via .chezmoitemplates/omp-settings-validate.tmpl.
for item in "run_after_config-omp-auth.sh.tmpl:auth.sh" \
            "run_onchange_after_update-omp-plugins.sh.tmpl:plugins.sh" \
            "run_after_config-omp-settings.sh.tmpl:settings.sh"; do
  render < ".chezmoiscripts/70-agents/${item%%:*}" > "$scratch/${item#*:}"
done
for item in "run_after_config-omp-auth.ps1.tmpl:auth.ps1" \
            "run_onchange_after_update-omp-plugins.ps1.tmpl:plugins.ps1" \
            "run_after_config-omp-settings.ps1.tmpl:settings.ps1"; do
  render --override-data '{"chezmoi":{"os":"windows"}}' \
    < ".chezmoiscripts/70-agents/${item%%:*}" > "$scratch/${item#*:}"
done
mkdir -p "$scratch/haptic-package/dist"
render < "dot_local/share/omp-plugins/plugins/mxm4-haptic/package.json.tmpl" \
  > "$scratch/haptic-package/package.json"
(cd packages/mxm4-haptic && vp run build:omp-plugin)
cp packages/mxm4-haptic/dist/omp-plugin/index.js "$scratch/haptic-package/dist/index.js"
chmod 700 "$scratch/auth.sh" "$scratch/plugins.sh" "$scratch/settings.sh"

# 2. Every declared selector must exist in the live catalog.
printf '{{ toJson .agents.omp.settings }}' | render > "$scratch/omp-settings.json"
omp models --json | jq -r '.models[].selector' | sort > "$scratch/avail.txt"
jq -r 'def strip: sub(":(off|minimal|low|medium|high|xhigh|max)$"; "");
  . as $s
  | [ ($s.modelRoles // {} | to_entries[].value),
      ($s."task.agentModelOverrides" // {} | to_entries[].value),
      ($s."retry.fallbackChains" // {} | to_entries[].value[]) ]
  | map(select(type == "string"))
  | map(if startswith("@") then ($s.modelRoles[.[1:]] // .) else . end)
  | map(select(startswith("@") | not) | strip) | unique[]' \
  "$scratch/omp-settings.json" | sort > "$scratch/used.txt"
comm -23 "$scratch/used.txt" "$scratch/avail.txt"     # must print nothing

# 2b. Every role's resolution path (own selector + chain) must reach both
#     high-headroom providers (rule 6).
jq -r '. as $s | ($s.modelRoles // {}) as $r
  | ($s."retry.fallbackChains" // {}) | to_entries[]
  | . as $c
  | (($r[$c.key] // "") | if startswith("@") then ($r[.[1:]] // "") else . end) as $own
  | ([$own] + $c.value) as $path
  | ["anthropic","opencode-go"]
  | map(select(. as $p | ($path | map(startswith($p + "/")) | any) | not))
  | if length > 0 then "UNANCHORED PATH \($c.key): missing \(join(", "))" else empty end' \
  "$scratch/omp-settings.json"     # must print nothing

# 3. Both platform halves must assert the same declared key set and plugin state.
.ci/test-omp-agent-reconcile.sh \
  "$scratch/auth.sh" "$scratch/auth.ps1" \
  "$scratch/plugins.sh" "$scratch/plugins.ps1" \
  "$scratch/haptic-package" "$scratch/settings.sh" "$scratch/settings.ps1"

# 4. model-notes.md must (a) carry no specs, (b) cover every declared
#    selector's family, and (c) agree with agents.yaml on role -> family.
node -e '
const fs=require("fs"),d=process.argv[1],p=process.argv[2];
const lines=fs.readFileSync(p,"utf8").split("\n");
const fam=new Map(); let cur=null, bad=0, started=false; const rows=[];
lines.forEach((ln,i)=>{
  if(/^## /.test(ln)) started=true;
  const h=ln.match(/^### (.+?)\s*$/); if(h){ cur=h[1]; fam.set(cur,[]); return; }
  const m=ln.match(/^ids:\s/);
  if(m&&cur){ for(const g of ln.match(/`[^`]+`/g)||[]) fam.get(cur).push(g.slice(1,-1)); return; }
  const row=ln.match(/^\|\s*`([^`]+)`\s*\|[^|]*\|\s*([^|]+?)\s*\|/); if(row) rows.push(row);
  if(!started||/https?:\/\//.test(ln)) return;
  const leak=ln.match(/\d{1,3}(?:,\d{3})+|\$\s?\d|\b\d+k\b|context window|max output|\btokens?\b|per 1M/i);
  if(leak){ console.log("SPEC LEAK line "+(i+1)+": "+leak[0]); bad++; }
});
const toRe=g=>new RegExp("^"+g.replace(/[.+^${}()|[\]\\]/g,"\\$&").replace(/\*/g,".*")+"$");
const all=[...fam.values()].flat().map(toRe);
for(const sel of fs.readFileSync(d+"/used.txt","utf8").split("\n").filter(Boolean))
  if(!all.some(r=>r.test(sel))){ console.log("NO FAMILY ENTRY covers "+sel); bad++; }
const s=JSON.parse(fs.readFileSync(d+"/omp-settings.json","utf8"));
const roles=s.modelRoles||{}, ovr=s["task.agentModelOverrides"]||{};
const deref=v=>{ let n=0; while(typeof v==="string"&&v.startsWith("@")&&n++<8) v=roles[v.slice(1)]; return (v||"").replace(/:(off|minimal|low|medium|high|xhigh|max)$/,""); };
for(const [,role,family] of rows){
  const raw = role in ovr ? ovr[role] : roles[role]; if(raw===undefined) continue;
  if(!fam.has(family)){ console.log("TABLE names unknown family \""+family+"\" for "+role); bad++; continue; }
  const sel=deref(raw);
  if(!fam.get(family).map(toRe).some(r=>r.test(sel))){
    console.log("ROLE/FAMILY MISMATCH "+role+" -> "+sel+" is not in \""+family+"\""); bad++; }
}
console.log("notes: families="+fam.size+" mapped-roles="+rows.length+" problems="+bad);
if(bad) process.exit(1);
' "$scratch" .agents/skills/sync-omp-models/model-notes.md

rm -rf "$scratch"
```

Pass conditions: every render exits 0, the `comm` prints nothing, the reconcile
test ends with `omp auth, plugin, and settings reconcile tests passed`, and the
notes check reports `problems=0`. Purge `$scratch` even on failure — the rendered
scripts carry credential material whenever the render path was not stubbed.

## Report

Summarize: which roles, overrides, and chain entries changed; every override
dropped as a no-op against bundled frontmatter and every one kept with its
justification; any bundled agent now pinned by its own frontmatter because the
data stays silent about it; anything dropped as unavailable and what got
promoted; any provider that is unauthenticated or out of quota, and how that
changed chain order. List every version float applied and any capability it
regressed, every cross-series candidate raised as a proposal and left
unapplied, and every new catalog id parked with the reason. State whether the
four job shapes still land on four providers. Note that a running omp session
must be restarted to pick up
changes, and that the values only reach `~/.omp/agent/config.yml` on the next
`chezmoi apply`. Do not commit unless asked.
