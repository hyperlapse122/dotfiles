---
description: Sync oh-my-openagent agent/category model mappings in .chezmoidata/agents.yaml to the upstream reference, resolved against locally available `opencode models`.
---

Update **only** `agents.opencode.ohMyOpenagent.agents` and
`agents.opencode.ohMyOpenagent.categories` in `.chezmoidata/agents.yaml` so they
faithfully mirror the upstream oh-my-openagent reference, resolved against the
models actually available on THIS host. Do not touch `model`, `smallModel`,
`providers`, `plugins`, or anything outside those two maps. Do not commit.

Current file to edit: @.chezmoidata/agents.yaml

Additional overrides for this run (optional): $ARGUMENTS

## Inputs (already fetched for you)

Available models on this host (`opencode models --refresh`):

!`opencode models --refresh`

Upstream reference — per-AGENT fallback chains
(`packages/model-core/src/agent-model-requirements.ts`, `dev`):

!`curl -fsSL https://raw.githubusercontent.com/code-yeongyu/oh-my-openagent/dev/packages/model-core/src/agent-model-requirements.ts`

Upstream reference — per-CATEGORY fallback chains
(`packages/model-core/src/category-model-requirements.ts`, `dev`):

!`curl -fsSL https://raw.githubusercontent.com/code-yeongyu/oh-my-openagent/dev/packages/model-core/src/category-model-requirements.ts`

If any of the three blocks above is empty or errored, STOP and report it — do
not guess from memory.

## How to translate each `fallbackChain`

Each reference entry is `{ providers: [...], model, variant? }`. Convert the
ordered chain into the yaml shape (`model` + optional `variant`, then
`fallback_models`) as follows:

1. **Resolve each entry to ONE `provider/model`.** Pick the provider by model
   family, using whatever is present in the available-models list above:
   `claude-*`→`anthropic`, `gpt-*`→`openai`, `glm-*`→`zai-coding-plan`,
   `k2*`/`kimi-*`→`kimi-for-coding`, `gemini-*`→`google-agy`,
   `big-pickle`→`opencode`. (The reference's own `providers` array lists
   fallbacks like `github-copilot`/`vercel`/`opencode-go` that are not
   configured here; collapse to the family's serving provider.)
2. **Map reference model names to the available equivalent** (reference name →
   available id):
   - `kimi-k2.6` → `kimi-for-coding/k2p6`
   - `kimi-k2.5` / `k2p5` → `kimi-for-coding/k2p5`
   - `glm-5` → `zai-coding-plan/glm-5.1` (the non-turbo GLM-5 tier; keep
     `glm-5.2` distinct → `zai-coding-plan/glm-5.2`)
   - `glm-4.6v` → **drop**. The closest available match
     `zai-coding-plan/glm-5v-turbo` is a vision-tier model not served under
     the GLM Coding Plan subscription this repo authenticates against — it is
     listed by `opencode models` but every ping against it hangs and times out
     with an empty response, so it can never satisfy the ping gate below. No
     other GLM family member is a viable vision-fallback substitute under this
     tier, so this reference name has no mapping and the entry drops entirely.
   - `gemini-3.1-pro` → `google-agy/gemini-pro-agent`
   - `gemini-3-flash` → `google-agy/gemini-3-flash`
   - `claude-opus-4-7` with `variant: max` → `anthropic/claude-opus-4-8` with
     `variant: xhigh` (Anthropic's own recommendation: the 4-8 generation
     supersedes 4-7 and `xhigh` is the recommended reasoning tier). Every
     `claude-opus-4-7` occurrence in the current upstream reference carries
     `variant: max`, so this remap is effectively unconditional today; if a
     future reference ever emits `claude-opus-4-7` without that variant,
     resolve verbatim to `anthropic/claude-opus-4-7` and flag it in your
     summary.
   - `claude-sonnet-4-6`, `claude-haiku-4-5`, `gpt-5.x`, `big-pickle`, and any
     name that already appears verbatim → use as-is.
   - Any other name: use the CLOSEST available id in the same family; if there
     is none, treat it as a drop (next rule) and flag it in your summary.
3. **Drop** any entry whose resolved id is NOT in the available-models list
   (e.g. `minimax-*`, `qwen*`, `*-nano`, `gemini-3-flash-*` variants you didn't
   map, or any family with no configured provider). A dropped primary promotes
   the next surviving entry.
4. **Preserve the reference `variant` verbatim** on every surviving entry
   (including on `gemini-*` → `google-agy/*`), except where rule 2 explicitly
   remaps model+variant together — currently only `claude-opus-4-7` with
   `variant: max` → `claude-opus-4-8` with `variant: xhigh`.
5. **Dedupe**: after mapping, collapse entries that resolve to the same
   `provider/model` (+ variant), keeping the first occurrence's position.
6. The first surviving entry becomes `model` (+ `variant`); the rest become
   `fallback_models` in order. A bare `provider/model` string is fine when there
   is no variant; use the `{ model: ..., variant: ... }` object form when there
   is one — match the existing style in the file.

Cover every agent and every category present in the reference. Keep the two
`# Model Mapping Reference:` comment blocks intact.

## Ping-check every distinct model (required, before writing the file)

A model listed by `opencode models` can still be unreachable right now — auth
expired, provider throttling, or a delisted id that hasn't yet propagated to the
local refresh. Before you edit `.chezmoidata/agents.yaml`, live-check every
`provider/model` the mapping is about to reference:

1. **Collect every distinct `provider/model` pair** across the resolved mapping
   — both `model` and every entry in `fallback_models`, agents + categories.
   Dedupe: one ping per pair, never per usage.
2. **Ping each pair from a clean scratch dir** — never from this repo. `opencode
   run` walks up from CWD picking up the nearest `opencode.json` + `AGENTS.md`;
   from the chezmoi source that pulls in the repo's config, skills, and MCP
   servers, all noise for a liveness check (and any one of them can fail-loud
   on an unrelated concern and mask a genuine model verdict):

   ```sh
   ping_dir="${XDG_RUNTIME_DIR:-$HOME/.cache}/agent-scratch/omo-ping"
   mkdir -p "$ping_dir"
   # for each distinct provider/model in the resolved mapping:
   ( cd "$ping_dir" && opencode run --model "<provider>/<model>" "ping" )
   # …at the end of the ping-check phase:
   rm -rf "$ping_dir"
   ```

   Reuse the same `$ping_dir` for every ping in this run; the subshell keeps
   your own CWD on the chezmoi source unchanged.

3. **Classify the outcome**:
   - Exit 0 with any short coherent reply → USABLE, keep as mapped.
   - Non-zero exit, an auth / rate-limit / 5xx / timeout error, or an obviously
     empty response → UNUSABLE on this host right now. Treat exactly like a
     model missing from `opencode models` (rule 3 above): drop from every
     fallback chain, promote the next surviving entry to `model` where needed,
     and flag it in your report.
4. If ping-drops empty an agent's or category's chain entirely, fall back to
   the last-known survivor from the reference (verbatim, variant preserved) and
   flag it loudly — never leave the entry without a `model`.
5. Cache the verdict per pair within this run. Never re-ping the same
   `provider/model` twice, and space pings on the same provider apart if you
   start seeing rate-limit responses.

Only after every remaining pair in the final mapping pings USABLE may you write
`.chezmoidata/agents.yaml`.

## Verify before finishing (required)

Render the consuming template with the isolated op-stub recipe (never touches
`$HOME` or real 1Password) and assert: exit 0, valid JSON, and EVERY referenced
model exists in `opencode models`:

```sh
scratch="${XDG_RUNTIME_DIR:-$HOME/.cache}/agent-scratch/omo-verify"
mkdir -p "$scratch/bin" "$scratch/target"; : > "$scratch/empty.toml"
printf '#!/usr/bin/env bash\nprintf dummy-secret\n' > "$scratch/bin/op"; chmod 700 "$scratch/bin/op"
env PATH="$scratch/bin:$PATH" GITHUB_TOKEN="$(gh auth token 2>/dev/null)" \
  chezmoi --config "$scratch/empty.toml" --source "$PWD" --destination "$scratch/target" \
  execute-template < dot_config/opencode/readonly_oh-my-openagent.json.tmpl > "$scratch/omo.json"
opencode models > "$scratch/avail.txt"
node -e 'const fs=require("fs"),d=process.argv[1];const A=new Set(fs.readFileSync(d+"/avail.txt","utf8").split("\n").map(s=>s.trim()).filter(Boolean));const j=JSON.parse(fs.readFileSync(d+"/omo.json","utf8"));const R=new Set();const c=o=>{for(const v of Object.values(o)){if(v.model)R.add(v.model);for(const f of (v.fallback_models||[]))R.add(typeof f==="string"?f:f.model);}};c(j.agents||{});c(j.categories||{});const m=[...R].filter(x=>!A.has(x)).sort();console.log("distinct:",R.size,"| MISSING:",m.length?m:"NONE");' "$scratch"
rm -rf "$scratch"
```

`MISSING: NONE` is the pass condition. If anything is missing, fix the mapping
and re-run.

## Report

Summarize: which agents/categories changed, notable promotions/demotions vs the
previous state, anything dropped as unavailable, and any reference model you
could not resolve. Note that opencode must be restarted for a live session to
pick up config changes. Do not commit unless asked.
