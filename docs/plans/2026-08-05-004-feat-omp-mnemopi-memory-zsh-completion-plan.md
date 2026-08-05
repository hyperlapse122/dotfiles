---
title: "feat: enable omp mnemopi memory and install zsh completion"
date: 2026-08-05
type: feat
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
execution: code
product_contract_source: ce-plan-bootstrap
---

# feat: enable omp mnemopi memory and install zsh completion

## Goal Capsule

- **Objective:** Declare `memory.backend: mnemopi` in the chezmoi-managed omp settings so omp's local SQLite memory backend is active, and install `omp completions zsh` output as a real, loadable zsh completion function.
- **Authority:** The user request names both the exact setting (`memory.backend` → `mnemopi`, per <https://omp.sh/docs/memory>) and the exact generator command (`omp completions zsh`). Repository chezmoi conventions govern placement, fingerprinting, gating, and verification.
- **Execution profile:** One data-line settings change, one zsh startup-file edit, one new apply-time generator script, and one isolated CI test. Do not apply the source state to the live home directory.
- **Stop conditions:** Stop if `~/.local/share/zsh/site-functions` cannot be placed on `$fpath` ahead of prezto's `compinit`, or if the completion generator cannot be made to fail closed on truncated output.
- **Tail ownership:** Commit, push, PR creation, CI, and review handling are owned by the invoking LFG pipeline.

---

## Product Contract

### Summary

Two independent omp customizations land together. First, `agents.omp.settings` gains a single declared leaf path, `memory.backend: mnemopi`, which the existing `run_after_config-omp-settings.sh.tmpl` provisioner asserts into `~/.omp/agent/config.yml` with no script change. Second, omp's zsh completion is generated at apply time into the repo's existing-but-currently-inert `~/.local/share/zsh/site-functions/` directory, and that directory is finally added to `$fpath` so zsh's completion system can actually load it.

### Problem Frame

**Memory.** omp's memory is `off` by default (verified: `omp config get memory.backend` → `off`). The `mnemopi` backend is local, SQLite-backed, and needs no server, unlike `hindsight`. `omp config list` exposes `memory.backend` as a real settable leaf with the enum `off|local|hindsight|mnemopi`, while `mnemopi` alone is rejected (`Unknown setting: mnemopi`) — every mnemopi knob is its own leaf path. That shape is exactly what `agents.omp.settings` already is: a flat literal-path→value map, not a nested config document.

**Completions.** The repo's visible zsh-completion convention is `source <(kubectl completion zsh)` in `dot_config/zsh/dot_zshrc` (lines 16, 19, 22). Copying it for omp is the obvious move and the wrong one: measured on this host, `omp completions zsh` takes **0.64s** against kubectl 0.033s, minikube 0.062s, and helm 0.034s. One more `source <(...)` line would take interactive-shell completion overhead from roughly 0.13s to 0.77s — a delay on every new terminal and every tmux pane, in a repo that already spends effort on zsh startup speed (`dot_config/zsh/dot_zlogin` compiles the completion dump to `.zwc` purely for that reason).

A second, quieter convention already exists for exactly this case: `dot_local/share/zsh/site-functions/` is a chezmoi-managed target (`.gitkeep`), and `.chezmoiexternals/dev-tools.toml` lines 57-62 (`[buf-zsh-completion]`) extracts a prebuilt `_buf` into it. That path costs zero shell-startup time because `compinit` autoloads lazily. It is also **broken**: `zsh -lic 'print -l $fpath'` on this host returns only the four prezto module directories plus `/usr/local/share/zsh/site-functions`, `/usr/share/zsh/site-functions`, and `/usr/share/zsh/5.9/functions`. `~/.local/share/zsh/site-functions` is absent from `$fpath`, and no repo file adds it, so the deployed `_buf` has never loaded. Installing `_omp` there without fixing `$fpath` would produce the same silent no-op.

### Requirements

- R1. `.chezmoidata/agents.yaml` declares `memory.backend: mnemopi` under `agents.omp.settings`, so the existing settings provisioner asserts omp's local Mnemopi backend on every apply.
- R2. No other `memory.*` or `mnemopi.*` path is declared; mnemopi's documented defaults govern scoping, recall, retention, embeddings, and LLM mode.
- R3. `omp completions zsh` output is installed at apply time as `~/.local/share/zsh/site-functions/_omp`.
- R4. `~/.local/share/zsh/site-functions` is on `$fpath` before prezto's `compinit` runs, for every interactive zsh regardless of login state or `SHLVL`. This also makes the already-deployed `_buf` load for the first time.
- R5. A successful install invalidates prezto's completion dump, so the new completion is live on the next shell rather than up to 20 hours later.
- R6. The generator is idempotent, re-runs when the locked omp version changes, and never leaves a truncated or non-completion file at the target path.
- R7. Interactive zsh startup cost does not increase measurably; no new work runs per shell.
- R8. CI proves the generator's install, fail-closed, and soft-skip behavior, and proves the `$fpath` entry precedes prezto initialization.
- R9. Verification is isolated from the deployed home directory; no `chezmoi apply` against live `$HOME`.

### Scope Boundaries

- **In scope:** One declared omp settings path; the `$fpath` fix in the managed zshrc; a new POSIX-gated `run_onchange_after_` completion generator under `.chezmoiscripts/70-agents/`; one isolated CI test plus its workflow job and `delivery` wiring.
- **Out of scope:** Changing the existing `source <(kubectl|minikube|helm completion zsh)` lines (they are cheap and working — converting them is a separate, unrequested refactor); a Windows PowerShell counterpart (zsh and prezto are already `{{ if ne .chezmoi.os "windows" }}`-gated in `.chezmoiexternals/system.toml`); any `modelRoles` / `task.agentModelOverrides` / `retry.fallbackChains` change (the `sync-omp-models` skill is therefore not in play); bash or fish completions; applying the source state to live `$HOME`.

### Deferred to Follow-Up Work

- `mnemopi.embeddingVariant: multilingual` (`intfloat/multilingual-e5-large`, 1024d) instead of the `en` default (`BAAI/bge-base-en-v1.5`, 768d). The user's prompts are Korean, and an English-only embedding model degrades vector recall over Korean transcripts; FTS recall is unaffected. Not declared here because it was not requested and the trade is unmeasured on this host — the multilingual model is roughly 5x larger and slower per embedding. The switch costs an embedding rebuild on the next writable start, so it gets more expensive as the store grows. Reassessment trigger: revisit before the mnemopi store passes roughly 30 days of retained sessions, or sooner if recall visibly misses Korean-language context. One data line under `agents.omp.settings`.
- `autolearn.enabled: true`, which adds the `learn` tool. mnemopi already exposes `recall`, `retain`, `reflect`, and `memory_edit` without it.
- Converting the three existing `source <(...)` completion lines to generated `site-functions` files, now that `$fpath` works.

### Key Decision

- **Install omp's completion as an `$fpath` function rather than sourcing it per shell** (session-settled: user-directed — chosen over adding a fourth `source <(omp completions zsh)` line beside kubectl/minikube/helm). The user specified the generator command, not the wiring. Measured cost decides the wiring: a median 0.711s per shell versus zero. The `site-functions` target directory and the `_buf` precedent already exist in this repo, so this completes an existing convention instead of introducing a second one. Governs R3, R4, R7.

---

## Planning Contract

### Key Technical Decisions

- KTD1. **Generated `_omp` in `site-functions`, not `source <(...)` in `.zshrc`.** Measured on this host over 5 consecutive warm trials: `omp completions zsh` at 0.886s / 0.756s / 0.701s / 0.715s / 0.711s (median 0.711s), against kubectl 0.033s, minikube 0.062s, helm 0.034s. The decisive comparison is not the ratio but the baseline: a warm `zsh -ic exit` on this host costs 0.766s-0.802s, so a fourth `source <(...)` line would roughly **double** interactive shell startup, on every terminal and every tmux pane. `compinit` autoloading from `$fpath` is lazy and costs nothing at startup. The measurement is single-host; it is the host this repo provisions, and the absolute cost is large enough that plausible variance on other hardware does not change the conclusion. Governs R3, R7.
- KTD2. **Add `~/.local/share/zsh/site-functions` to `$fpath`.** `zsh -lic 'print -l $fpath'` returns only the four prezto module directories plus `/usr/local/share/zsh/site-functions`, `/usr/share/zsh/site-functions`, and `/usr/share/zsh/5.9/functions` — the managed directory is absent, so the `_buf` file that `.chezmoiexternals/dev-tools.toml` already deploys there is unreachable. That is evidence of *unreachability*, not proof the omission was accidental; no repo file or comment records an intent either way. The label does not change what gets built, because R4 is load-bearing for R3 regardless: without the entry, `_omp` is written and never read. Governs R4.
- KTD3. **The `fpath` line goes in `dot_config/zsh/dot_zshrc` immediately above the prezto init block, not in `.zprofile` or `.zshenv`.** `.zprofile` runs only for login shells and, via `dot_config/zsh/dot_zshenv` lines 11-13, for `SHLVL -eq 1 && ! -o LOGIN`; `fpath` is a shell array and is not exported, so a nested interactive shell (`SHLVL > 1`, the common tmux and subshell case) would silently lose the entry. `.zshrc` runs for every interactive shell, already owns the other completion wiring, and — critically — must set `fpath` *before* line 9-11 sources `${ZDOTDIR:-$HOME}/.zprezto/init.zsh`, because prezto's `completion` module (enabled at position 10 of 14 in `dot_config/zsh/dot_zpreztorc`) is what calls `compinit`. `.zshenv` would also work but runs for non-interactive scripts where completion is irrelevant. Governs R4.
- KTD4. **`run_onchange_after_` fingerprinted on the locked omp version, not on `.chezmoidata/releases.json` content.** Completion output is a function of the omp binary, and the binary is pinned by the release lock. Resolve the version through `.chezmoitemplates/release-lock-ref.tmpl` (`dict "ctx" $ctx "tool" "omp"`) — the repo's only sanctioned lock consumer — and render it into a comment line so that comment *is* the onchange trigger, exactly as `.chezmoiscripts/00-tools/run_onchange_after_winbox-macos.sh.tmpl` lines 8-9 do (`{{- $winboxVersion := (includeTemplate "release-lock-ref.tmpl" ...) -}}` on one line, `# winbox version: {{ $winboxVersion }}` on the next). Do **not** copy `run_onchange_after_update-omp-plugins.sh.tmpl`: its version lookup renders zero bytes and its real trigger is a `fingerprint.tmpl` hash over a glob list that includes `.chezmoidata/releases.json` — precisely the over-broad hash that would regenerate this completion on every unrelated hourly lock refresh. The `after` phase is required: omp is a chezmoi `file` external landing at `~/.local/bin/omp`, so it exists only once the FILE phase has run.
  **Alternative weighed and rejected: vendor a committed `_omp`.** Generating the file once and committing it as a managed target would delete U3 and most of U4 outright. It is rejected because nothing would then bind the completion to the installed binary: `.github/workflows/refresh-release-lock.yml` re-resolves the lock hourly and commits on any change, so omp version bumps land automatically while a committed snapshot would only update when a human remembered — silently offering flags and subcommands the installed omp no longer has, with no gate to catch the drift. It also cuts against the repo's standing rule that generated artifacts are not hand-edited. The `[buf-zsh-completion]` external is not a counterexample: it pulls a prebuilt completion *out of the pinned release archive*, so it is version-bound by construction. omp publishes no completion asset, so generating from the pinned binary is the only way to get the same guarantee. Governs R6.
- KTD5. **Two distinct protections, not one.** (a) *Malformed output* — require the temp file to be non-empty with `#compdef omp` as its exact first line. This is the observed hazard: `omp completions zsh | head -3` on this host emits the correct header and then dumps omp's own bundled JavaScript source into the stream (`732312 | j.set(u.name, g);`), because omp mishandles a closed stdout. A plain `>` redirect never closes early, so the apply path does not reach that bug — the guard covers it and any future bad-output shape. (b) *Interrupted write* — generate into a temp file in the target directory and `mv` it into place, so a process kill or full disk can never leave a half-written file at the target path. The shape guard does not defend (b) and the atomic rename does not defend (a); a maintainer changing either behavior should know which one they are touching. On any failure exit non-zero and leave the previous file untouched. Never pipe the generator into `head` or any early-closing reader. Governs R6.
- KTD6. **Delete prezto's completion dump after a successful install; do not backdate it.** `~/.config/zsh/.zprezto/modules/completion/init.zsh` calls `compinit -C -d "${XDG_CACHE_HOME:-$HOME/.cache}/prezto/zcompdump"` whenever that dump is less than 20 hours old; `-C` skips the `$fpath` function scan, so a freshly written `_omp` stays invisible until the dump ages out. Backdating the dump's mtime past the threshold looks gentler but is actively wrong here: `dot_config/zsh/dot_zlogin` line 12 recompiles the `.zwc` only when the dump is *newer* than it, so a backdated dump leaves a stale compiled `.zwc` in place and zsh keeps serving it. Delete both the dump and its `.zwc` sibling, tolerating absent files, and only after the install succeeds. The cost is one regenerated cache on the next shell. Governs R5.
- KTD7. **Declare `memory.backend` only.** `omp config list` shows `mnemopi.scoping = per-project`, `mnemopi.autoRecall = true`, `mnemopi.autoRetain = true`, `mnemopi.llmMode = smol`, and `mnemopi.embeddingVariant = en` as defaults that already suit this host. Declaring a default restates it in a second place and makes an upstream default change invisible. `memory.backend` also satisfies every gate in `.chezmoitemplates/omp-settings-validate.tmpl`: it matches the dotted path grammar, its string value `mnemopi` is inside the safe charset, it carries no `op://` reference, and it is not a parent namespace of any other declared path. Governs R1, R2.
- KTD8. **The generator lives in `.chezmoiscripts/70-agents/` and is POSIX-gated.** That directory owns omp plugins, settings, auth, and updates; a completion for the omp CLI is an omp concern. Gate with `{{ if ne .chezmoi.os "windows" }}` to match the prezto external in `.chezmoiexternals/system.toml` line 49. No container gate: `70-agents/` is absent from the container-excluded blocks in the root `.chezmoiignore`, omp is provisioned in containers, and CLI dotfiles are kept there. Governs R3.

### Assumptions

- mnemopi's default `llmMode: smol` resolves the pi-ai `tiny` role first. `agents.omp.settings.modelRoles` declares `tiny: "@bulk"` → `google-antigravity/gemini-3.1-flash-lite`, so LLM-backed memory work resolves without any model-role change. If no tiny/smol model resolves, mnemopi documents that it continues without LLM-backed work rather than failing.
- The on-device embedding model downloads on the first writable mnemopi start. A one-time first-session delay after this change is expected, not a defect.
- Backend startup is best-effort by design: mnemopi documents that a database or model initialization failure leaves the session usable with memory inert. Enabling the backend therefore cannot break omp sessions.
- Vector recall over Korean is knowingly degraded for the interim, because the `en` embedding default is English-only; FTS recall is unaffected, so memory is useful but not at full strength for this user's primary prompt language. This is accepted rather than overlooked — see the reassessment trigger under Deferred to Follow-Up Work.

### Verification Contract

- Render every changed template with `chezmoi execute-template` under the AGENTS.md scratch-and-stub recipe (`--source "$PWD"`, throwaway destination, empty config, stub `op`), and compare rendered script text before and after. Scripts are not targets, so archive comparison does not cover them.
- Run `.ci/test-omp-zsh-completion.sh` locally and confirm it passes.
- Run `.ci/test-omp-agent-reconcile.sh` against the newly rendered settings script and confirm the declared-path count and per-path assertions still pass with the new key.
- Prove the completion end to end in an isolated zsh: with `fpath` containing a scratch `site-functions` holding the real generated `_omp`, a `compinit`-initialized `zsh -f` resolves `_omp` as an autoloadable function.
- Never `chezmoi apply` against the live home directory.

---

## Implementation Units

### U1. Declare `memory.backend: mnemopi`

**Goal:** Turn on omp's local Mnemopi memory backend through the existing data-driven settings provisioner.

**Requirements:** R1, R2. Implements KTD7.

**Dependencies:** none.

**Files:**
- `.chezmoidata/agents.yaml` (modify)

**Approach:**
1. Add a single entry under `agents.omp.settings`, placed with the other non-model literal paths (near `symbolPreset` / `defaultThinkingLevel` / the `skills.*` and `astGrep.enabled` block around lines 435-451), **not** inside the model section that `.agents/skills/sync-omp-models/SKILL.md` owns:
   `memory.backend: mnemopi`
2. Add a short comment stating that only the backend selector is declared and mnemopi's defaults (`scoping: per-project`, `autoRecall`/`autoRetain` on, `llmMode: smol` resolving the declared `tiny` role) govern the rest, so a future reader does not mistake the absence of `mnemopi.*` keys for an oversight.
3. Change nothing else. `run_after_config-omp-settings.sh.tmpl` is fully generic over declared keys: it serializes the whole map with `toPrettyJson` at render time and emits one `omp config set <path> <value>` per top-level key, with string values passed verbatim. The render-time gate `.chezmoitemplates/omp-settings-validate.tmpl` needs no change either.

**Patterns to follow:** the existing flat literal-path entries in `agents.omp.settings` (`theme.dark`, `exa.enabled`, `skills.enableCodexUser`, `computer.enabled`).

**Test scenarios:**
- `.ci/test-omp-agent-reconcile.sh` derives its expectations from the rendered declared JSON, so it must now assert exactly one `config set memory.backend mnemopi` call, at the exact value, and its total-count assertion must reflect the new declared-path count. Confirm the existing generic assertions cover this without new scaffolding; add none if they do.
- Render-negative regression: the pairwise parent-namespace gate must still pass, i.e. no declared path is a dotted prefix of `memory.backend` and `memory.backend` is a prefix of no other declared path.
- `Covers R1, R2.`

**Verification:** The rendered settings script's embedded `declared` heredoc contains `"memory.backend": "mnemopi"`, and the render-baked declared-path count in its truncated-stream guard increases by exactly one.

---

### U2. Put `~/.local/share/zsh/site-functions` on `$fpath`

**Goal:** Make the repo's existing `site-functions` directory actually loadable by zsh's completion system, ahead of prezto's `compinit`.

**Requirements:** R4. Implements KTD2, KTD3.

**Dependencies:** none. U3 depends on this to be useful, but the edits are independent.

**Files:**
- `dot_config/zsh/dot_zshrc` (modify)

**Approach:**
1. Insert, **above** the existing prezto init block at lines 9-11, an `fpath` prepend guarded on directory existence so a fresh or container host does not add a phantom entry — mirror the `(N)` null-glob qualifier style `dot_config/zsh/dot_zprofile` line 51-57 already uses for `path`.
2. Prepend rather than append, so a repo-managed completion wins over a system one of the same name.
3. Add a comment recording why the line must precede the prezto source: prezto's `completion` module is what calls `compinit`, and `compinit` only scans `$fpath` as it stands at that moment.
4. Do not touch `.zprofile` or `.zshenv` (KTD3), and do not remove or reorder the existing kubectl/minikube/helm lines.

**Patterns to follow:** `dot_config/zsh/dot_zprofile` lines 43-57 — `typeset -gU` deduplication plus `(N)`-qualified array assignment.

**Test scenarios:**
- A real `zsh -f` seeded with a scratch `site-functions` directory containing a `_omp` stub, that runs `compinit` after the same `fpath` prepend, resolves `_omp` as an autoloadable completion function.
- The same shell with the `fpath` prepend removed does **not** resolve `_omp` — this is what proves the line is load-bearing rather than incidental.
- Static ordering check: in `dot_config/zsh/dot_zshrc`, the `site-functions` `fpath` line number is strictly less than the line number of the `.zprezto/init.zsh` source.
- Non-existent directory: with the target directory absent, the guarded prepend adds no entry and the shell starts without error.
- `Covers R4.`

**Verification:** `zsh -lic 'print -l $fpath'` against the rendered zshrc lists `~/.local/share/zsh/site-functions`, and the previously dead `_buf` resolves too.

---

### U3. Generate `_omp` at apply time

**Goal:** Install `omp completions zsh` output as `~/.local/share/zsh/site-functions/_omp`, regenerating only when the locked omp version changes, and failing closed on bad output.

**Requirements:** R3, R5, R6, R7. Implements KTD1, KTD4, KTD5, KTD6, KTD8.

**Dependencies:** U2 (the file is inert until `$fpath` includes its directory).

**Files:**
- `.chezmoiscripts/70-agents/run_onchange_after_install-omp-zsh-completion.sh.tmpl` (create)

**Approach:**
1. Gate the whole template on `{{ if ne .chezmoi.os "windows" }}`, matching the prezto external's gate.
2. Resolve the locked omp version through `.chezmoitemplates/release-lock-ref.tmpl` with `dict "ctx" $ctx "tool" "omp"` and emit it in a comment-only fingerprint line — the same shape as `run_onchange_after_update-omp-plugins.sh.tmpl` line 6. This is the script's only dependency fingerprint; state that explicitly in the header comment per AGENTS.md.
3. Runtime body: `set -euo pipefail`; prepend `$HOME/.local/bin` to `PATH` when absent, because chezmoi's non-interactive script environment omits it (copy the reasoning and shape from `run_after_config-omp-settings.sh.tmpl`); soft-skip with `exit 0` and a stderr notice when `omp` is not resolvable.
4. `mkdir -p` the target directory, generate into `mktemp` **inside that same directory** so the later `mv` is a same-filesystem rename, then validate before installing: the temp file must be non-empty and its first line must be exactly `#compdef omp`. Fail non-zero with a clear message otherwise, leaving any existing `_omp` untouched. Redirect with `>`; never pipe the generator into an early-closing reader (KTD5).
5. `chmod 0644` and `mv` into place.
6. Only after a successful install, remove `${XDG_CACHE_HOME:-$HOME/.cache}/prezto/zcompdump` and `${...}/prezto/zcompdump.zwc` so the next shell rebuilds the dump and picks the new function up (KTD6). Removal must tolerate absent files.
7. `trap`-based cleanup of the temp file on every exit path.

**Execution note:** This is packaging and apply-time glue. The right first proof is the isolated CI harness in U4 driving the rendered script against a stub `omp`, not unit coverage.

**Patterns to follow:** `.chezmoiscripts/70-agents/run_after_config-omp-settings.sh.tmpl` for the PATH prepend, the soft-skip shape, and scratch/`trap` hygiene; `run_onchange_after_update-omp-plugins.sh.tmpl` line 6 for the release-lock-derived fingerprint.

**Test scenarios:**
- Happy path: with a stub `omp` emitting a valid `#compdef omp` script, the run exits 0 and writes exactly that content to `<target>/site-functions/_omp` at mode 0644.
- Idempotence: a second run with the same stub leaves byte-identical content and still exits 0.
- Truncated output: a stub emitting a non-empty payload whose first line is not `#compdef omp` makes the run exit non-zero, write no `_omp`, and leave a pre-existing `_omp` byte-identical.
- Empty output: a stub emitting nothing makes the run exit non-zero and leaves any pre-existing `_omp` byte-identical.
- Generator failure: a stub exiting non-zero makes the run exit non-zero and leaves any pre-existing `_omp` byte-identical.
- Soft-skip: with `omp` absent from `PATH`, the run exits 0, writes no `_omp`, and emits a recognizable notice on stderr.
- Dump invalidation: a pre-seeded `zcompdump` and `zcompdump.zwc` under a scratch `XDG_CACHE_HOME` are both gone after a successful run.
- Dump preserved on failure: those same files still exist after a failing run, because invalidation is gated on install success.
- Absent dump: a successful run with no pre-existing dump exits 0 rather than tripping on the missing file.
- Fingerprint: the rendered script text contains the locked omp version string, so a lock bump changes the rendered content and re-triggers the onchange script.
- No temp residue: no `mktemp` leftover remains in the target directory after either a successful or a failing run.
- R7 needs no test of its own: it is satisfied structurally, because `$fpath` autoloading does no work at shell startup. The only way to regress it is to reintroduce a per-shell `source <(...)` line, which the KTD1 rationale forbids.
- `Covers R3, R5, R6, R7.`

**Verification:** The rendered script, run against a stub `omp` in an isolated `HOME`, installs a valid `_omp`, and every failure case above leaves the target path unchanged.

---

### U4. CI proof and workflow wiring

**Goal:** Make the generator's behavior and the `$fpath` ordering enforceable in CI.

**Requirements:** R8, R9. Implements the Verification Contract.

**Dependencies:** U2, U3.

**Files:**
- `.ci/test-omp-zsh-completion.sh` (create)
- `.github/workflows/ci.yml` (modify)

**Approach:**
1. Write `.ci/test-omp-zsh-completion.sh` taking the rendered generator script as `$1`, mirroring the argument and scratch conventions of `.ci/test-omp-agent-reconcile.sh` and the isolated-server discipline of `.ci/test-tmux-kitty-passthrough.sh`.
2. Drive every U3 test scenario with a stub `omp` on a scratch `PATH`, a scratch `HOME`, and a scratch `XDG_CACHE_HOME`. Assert exit status, file content, file mode, stderr substrings, and the zcompdump side effects.
3. Add the U2 scenarios: a static assertion that the `site-functions` `fpath` line precedes the `.zprezto/init.zsh` source line in `dot_config/zsh/dot_zshrc`, and a real `zsh -f` run proving `_omp` resolves with the prepend and does not resolve without it.
4. Add a `zsh-omp-completion` job to `.github/workflows/ci.yml`, modeled directly on the `tmux-kitty-passthrough` job (lines 163-176): `runs-on: ubuntu-latest`, checkout, install the locked chezmoi the same way the `omp-agent-integration` job does, `sudo apt-get update && sudo apt-get install -y zsh`, render the generator to `$RUNNER_TEMP`, then run the test with that path.
5. Add the new job to the `delivery` aggregate job's `needs:` list **and** its per-job result environment block, so a skipped or failed job cannot pass silently — that block is the documented reason `delivery` exists.

**Patterns to follow:** `.ci/test-tmux-kitty-passthrough.sh` for isolated-runtime discipline and scratch-scoped sockets/paths; `.ci/test-omp-agent-reconcile.sh` for stub-binary construction and call logging; `ci.yml` lines 18-27 for the locked-chezmoi install and lines 163-176 for the apt-install-then-test job shape.

**Test scenarios:**
- The test script exits 0 on the current tree and exits non-zero when the `fpath` line is moved below the prezto source, when the `#compdef` guard is removed from the generator, or when the zcompdump invalidation is removed. Prove at least one of these negatives by temporary local mutation so the test is known to be load-bearing rather than vacuously green.
- The new CI job appears in both the `delivery` `needs:` list and its result environment block.
- `Covers R8, R9.`

**Verification:** `.ci/test-omp-zsh-completion.sh` passes locally against the rendered script, and `.ci/test-omp-agent-reconcile.sh` still passes with the U1 settings change in place.

---

## Risks

- **A malformed `_omp` breaks every interactive shell.** Highest-severity failure mode here, because a broken completion function is sourced by `compinit` in every new zsh. Mitigated by KTD5's shape guard and same-directory atomic rename, and by U3's four negative test scenarios asserting the previous file survives byte-identical.
- **`compinit -C` masks a successful install.** Without KTD6's dump invalidation the change appears not to work for up to 20 hours, inviting a wrong second fix. Mitigated by the invalidation step and its two dedicated test scenarios.
- **`$fpath` fix changes completion resolution for `buf`.** Adding the directory activates the previously dead `_buf`. That is the correct behavior and the reason the file was deployed, but it is a real behavior change on the next shell; note it in the PR description.
- **Memory backend enablement is broad but only partly reversible.** mnemopi begins retaining conversation turns to a local SQLite store. It is documented as best-effort at startup and inert on failure, so it cannot break sessions; `/memory clear` removes the databases and reverting the one data line restores `off`. Reverting does **not** un-write turns already retained, so the exposure below is not undone by turning the backend back off.
- **Retained transcripts are unredacted and unexpiring.** Conversation turns can carry secrets, tokens, `op://` references, private repo content, and PII. The sibling `local` backend explicitly documents that consolidated output is redacted for common secret/token patterns before it is written; the mnemopi backend documentation makes no equivalent claim, and there is no automatic retention limit, so content accumulates on disk indefinitely. Accepted for a single-user workstation, with two operational consequences to record in the PR description: run `/memory clear` deliberately rather than assuming rotation, and exclude the agent memories directory from any host-level backup or sync tooling. No code in this plan mitigates this; it is a disclosure, not a control.
- **R4 converts a dormant directory into a live code-load path.** Today nothing loads from `~/.local/share/zsh/site-functions`, so a write there is inert. After U2 it is prepended to `$fpath` ahead of the system completion directories, which means anything able to write a file there gains code execution the next time a matching completion is tab-triggered, and can shadow a system completion of the same name. Prepending is deliberate — a repo-managed completion should win — and the directory is inside a per-user `$HOME` with ordinary permissions, so this adds no hardening beyond that and grants nothing an attacker with `$HOME` write access did not already have.

## Definition of Done

- `memory.backend: mnemopi` is declared, and the rendered settings script asserts it.
- `_omp` is generated at apply time, installed atomically behind a shape guard, and reachable through `$fpath` before prezto's `compinit`.
- Prezto's completion dump is invalidated on successful install only.
- Interactive zsh startup gains no new per-shell work.
- `.ci/test-omp-zsh-completion.sh` exists, is wired into `ci.yml` and the `delivery` aggregate, and passes; `.ci/test-omp-agent-reconcile.sh` still passes.
- The changes are committed, pushed, reviewed, and carried by a green pull request.

## Sources & Research

- `omp://memory.md` and `omp://mnemosyne-memory-backend.md` — backend table, `memory.backend` enum, mnemopi settings and defaults, scoping, LLM/embedding resolution, shutdown durability.
- `omp config list` on this host — confirms `memory.backend = off (off|local|hindsight|mnemopi)` and that `mnemopi` is not itself a settable path.
- `omp completions zsh --help` and measured timings on this host — 0.64s versus kubectl 0.033s, minikube 0.062s, helm 0.034s; observed source-dump on early stdout close.
- `zsh -lic 'print -l $fpath'` on this host — proves `~/.local/share/zsh/site-functions` is absent from `$fpath`.
- `~/.config/zsh/.zprezto/modules/completion/init.zsh` — the 20-hour `compinit -C -d "${XDG_CACHE_HOME:-$HOME/.cache}/prezto/zcompdump"` cache.
- Repo: `.chezmoiscripts/70-agents/run_after_config-omp-settings.sh.tmpl`, `.chezmoitemplates/omp-settings-validate.tmpl`, `.chezmoitemplates/release-lock-ref.tmpl`, `.chezmoiexternals/dev-tools.toml` (`[buf-zsh-completion]`), `.chezmoiexternals/system.toml` (`[prezto]`), `dot_config/zsh/*`, `.ci/test-omp-agent-reconcile.sh`, `.ci/test-tmux-kitty-passthrough.sh`, `.github/workflows/ci.yml`.
