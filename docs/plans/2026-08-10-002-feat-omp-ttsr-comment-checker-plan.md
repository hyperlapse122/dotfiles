---
title: omp TTSR Comment Checker - Plan
type: feat
date: 2026-08-10
topic: omp-ttsr-comment-checker
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-brainstorm
execution: code
deepened: 2026-08-10
---

# omp TTSR Comment Checker - Plan

## Goal Capsule

- **Objective:** Port `code-yeongyu/go-claude-code-comment-checker` to omp TTSR as per-comment-syntax-family user rules deployed through this chezmoi source, covering all 31 languages of the original's registry, with the original's exception filters compiled into the trigger regexes, and flip the global `ttsr.repeatMode` to `after-gap` so rules keep reminding after their first trigger.
- **Product authority:** The Product Contract below and the dialogue behind it. The root `AGENTS.md` governs chezmoi source attributes, the data-over-script ownership rules, and isolated verification. omp's rule pipeline (`docs/rulebook-matching-pipeline.md`, `docs/ttsr-injection-lifecycle.md`, `packages/coding-agent/src/cli/ttsr-cli.ts` in `can1357/oh-my-pi`) governs every TTSR mechanism claim. The original project's Rust source (`src/language.rs`, `src/filters.rs`) governs the language registry and the exception catalog.
- **Execution profile:** Three units: six managed-readonly rule files under a new `dot_omp/private_agent/rules/` tree, one scalar settings leaf in `.chezmoidata/agents.yaml`, and one `.ci/` fixture test plus its `ci.yml` wiring. U3 depends on U1; U2 is independent.
- **Stop conditions:** Stop if the locked omp binary loses the `omp ttsr test --rule` / `omp ttsr list --json` surface the test harness builds on. Stop if the render-time settings validator rejects `ttsr.repeatMode: after-gap` (research says it passes; do not weaken a validator gate to force it). Never run `chezmoi apply` against live `$HOME` during verification.
- **Tail ownership:** Local proof is the new `.ci/test-omp-comment-rules.sh`, the existing `.ci/test-omp-agent-reconcile.sh` (which auto-covers the new settings key), and isolated renders with the scratch `op` stub. The pull request owns final `ci.yml` and `render-dotfiles.yml` proof. The R10 live-session dogfood is the user's manual observation, reported by this run and never performed silently.
- **Open blockers:** None.

**Product Contract preservation:** changed at plan time, each user-confirmed at the scoping synthesis: R2 (whole-turn sweep instruction added), R4 (Go directive exception extension), R5 (protocol-relative URL exclusion), R6 (strictness-dial pointer re-aimed at KTD3), R8 (docstring anchor and false-positive acceptance), F1 (per-batch single-reminder semantics). Deferred questions resolved: BDD matching semantics (KTD2), regex strictness dials (KTD3), per-language syntax completeness (KTD3). AE8–AE11 added for the confirmed changes. All other Product Contract entries unchanged.

---

## Product Contract

### Summary

A set of per-comment-syntax-family TTSR rule files (C-family, hash, dash, HTML/XML, OCaml, Python docstring) deploys as personal omp user rules managed by this dotfiles repo, covering every language the original checker supports. Each rule follows omp's bundled-default shape — `interruptMode: never`, per-language `scope` globs on edit/write tools, and a Why/Examples/Exceptions body — with the original's BDD/directive/shebang exceptions compiled into the trigger regexes and URLs excluded from triggering. The global `ttsr.repeatMode` moves to `after-gap` so a rule reminds again after the default 10-turn gap instead of going silent for the session.

### Problem Frame

The original tool is a Claude Code / OpenCode PostToolUse hook: an external binary that reads tool JSON, parses the written content with tree-sitter, and exits 2 to feed a warning back when it finds comments outside an allow-list. This dotfiles repo manages omp as the sole agent harness, so a Claude Code hook never fires here, and today nothing enforces the no-unnecessary-comments policy in omp sessions — the only adjacent policy is the prose clear-and-concise baseline in the shared instruction template.

omp's native enforcement surface is TTSR: markdown rules whose `condition` regexes match against the streamed, per-file source snapshots of edit/write tool calls, with matched rule content injected back to the model. One native surface is confirmed closed: `astCondition` cannot detect comments, because an ast-grep pattern must parse as a single AST node and tree-sitter comment nodes are trivia that a comment-only pattern cannot bind. This was verified empirically against fixtures (`// $X`, `/* $$$BODY */`, and `# $X` each returned zero matches on files containing those comments). Regex `condition` is therefore the only TTSR-native trigger path, which trades the original's tree-sitter precision for regex imprecision that the requirements below bound.

### Key Decisions

- KD1. **Personal dotfiles-managed user rules.** (session-settled: user-directed — chosen over a local omp plugin, a published marketplace plugin, and an upstream builtin contribution: the need is personal, and a managed rules tree is the lightest surface.) Governs R1.
- KD2. **Bundled-default behavior parity.** Rules mirror omp's 27 bundled rules: `interruptMode: never`, so a match prepends a reminder to the tool result instead of aborting the stream. (session-settled: user-directed — chosen over mid-stream interrupt-and-retry: it matches both the bundled convention and the original hook's post-write semantics, and keeps regex false positives harmless.) Governs R2.
- KD3. **Exception enforcement lives in the trigger regexes; the body keeps a documentary Exceptions section per the bundled shape.** The confirmed extension of the catalog with Go toolchain directives is recorded on R4. (session-settled: user-directed — chosen over delegating exceptions to an Exceptions section the model judges: a coarse trigger would spend reminder budget on allowed patterns such as shebangs.) Governs R4, R5.
- KD4. **Full registry parity: 31 languages.** The original README advertises "30+"; the registry carries exactly 31 distinct language names, and the port covers all of them. (session-settled: user-directed — chosen over covering only the user's working set: the port should match the original's reach.) Governs R7, R8.
- KD5. **Global `ttsr.repeatMode` becomes `after-gap`.** `repeatGap` stays at the built-in default of 10 completed turns. (session-settled: user-directed — chosen over the `once` default: the original hook fires on every write, so once-per-session silence is a parity gap. The setting is global, so bundled rules also remind more often; that is the accepted cost.) Governs R3.
- KD6. **One rule file per comment-syntax family.** (session-settled: user-approved — chosen over a single unified rule and over per-language files: a unified rule cannot pair each regex with the right file globs and would fire the hash regex on C preprocessor directives, while per-language files multiply near-identical bodies. Under `repeatMode` budgeting, the family split also grants each family its own reminder cadence.) Governs R1, R7.

### Requirements

**Delivery and configuration**

- R1. The port ships as one markdown rule file per comment-syntax family under a new chezmoi-managed `dot_omp/private_agent/rules/` tree, deploying to `~/.omp/agent/rules/`. omp's native provider (priority 100) loads `*.{md,mdc}` from that directory, so no script, plugin, or marketplace wiring is required; rule names must not collide with the bundled `go-*` / `rs-*` / `ts-*` names, because same-named user rules shadow bundled ones. The tree deploys to every managed host, including containers — the rules are inert markdown where omp does not run.
- R2. Each rule file declares frontmatter matching omp's bundled-default conventions: a one-line `description`, `condition` regexes, `interruptMode: never`, and a `scope` restricted to edit/write tool streams with per-extension globs (for example `tool:edit(*.py), tool:write(*.py)`). The scope must exclude `text` and `thinking` so comment markers in the agent's prose never trigger. Each rule body follows the bundled shape: an imperative opening line, a Why section, examples of violating and compliant code, and an Exceptions section. Each body also instructs the model to check every file it touched this turn, not only the flagged one — TTSR attaches at most one reminder per rule per matching batch (KTD8).
- R3. `.chezmoidata/agents.yaml` declares `ttsr.repeatMode: after-gap` under `agents.omp.settings`, reconciled by the existing per-key settings provisioner; `ttsr.repeatGap` is not declared and keeps the built-in default of 10, so a host where `repeatGap` was ever set by hand keeps that value (accepted drift, KTD7). Per KD5 this is a global change that also raises reminder frequency for the bundled rules.

**Trigger behavior**

- R4. Each rule's `condition` regexes match its family's comment syntax in streamed edit/write snapshots and must not match the allow-list: shebangs (`#!`); BDD step comments (keyword set `given, when, then, arrange, act, assert, when & then, when&then`, case-insensitive, keyword-prefix semantics per KTD2); and linter directives whose body, after an optional `@`, starts with one of `type:, noqa, pyright:, ruff:, mypy:, pylint:, flake8:, pyre:, pytype:, eslint-disable, eslint-ignore, prettier-ignore, ts-ignore, ts-expect-error, clippy:, allow, deny, warn, forbid` (case-insensitive, no trailing word boundary, matching the original's `starts_with`). The catalog deliberately extends the original with the Go toolchain prefixes `go:` and `nolint` (user-confirmed at planning: strict parity would remind on nearly every tagged Go file).
- R5. Condition regexes must not match URL forms: `scheme://` occurrences such as `https://example.com`, protocol-relative references such as `url(//cdn.example.com/x.png)` in CSS, and fragment references such as `page.html#section`.
- R6. Comment-like markers inside ordinary string literals (beyond the URL forms of R5) are an accepted residual false-positive class: the harm is one dismissible reminder per family per gap window. Strictness dials such as line anchoring are KTD3's domain.

**Coverage**

- R7. Coverage spans all 31 registry languages through six family rule files. Languages appearing in two families (php, svelte, and python — globbed as `py` by both the hash and docstring rules) are globbed by both rules.

| Family rule | Comment syntaxes | Languages | Scope extensions |
| --- | --- | --- | --- |
| C-family | `//`, `/* */` | javascript, typescript, tsx, go, java, kotlin, scala, c, cpp, rust, csharp, swift, proto, groovy, cue, php, svelte, css | js, jsx, ts, tsx, go, java, kt, scala, c, h, cpp, cc, cxx, hpp, rs, cs, swift, proto, groovy, cue, php, svelte, css |
| Hash | `#` | python, ruby, bash, yaml, toml, hcl, dockerfile, elixir, php | py, rb, sh, bash, yaml, yml, toml, hcl, tf, Dockerfile (basename), ex, exs, php |
| Dash | `--`, `/* */` (SQL), `{- -}` (Elm) | lua, sql, elm | lua, sql, elm |
| HTML/XML | `<!-- -->` | html, svelte | html, htm, svelte |
| OCaml | `(* *)` | ocaml | ml, mli |
| Python docstring | `"""`, `'''` | python | py |

- R8. Python module, class, and function docstrings are flagged as violations, matching the original's stance that docstrings are unnecessary comments. The trigger is anchored to bare triple-quoted strings at line start (KTD4), so assigned constants such as `QUERY = """..."""` do not trigger, while bare triple-quoted string statements outside docstring position do — an accepted, fixture-pinned false-positive class. JSDoc/Javadoc `/** */` blocks need no separate mechanism: they match the C-family block-comment regex.

**Verification**

- R9. A `.ci/` test in this repo's existing harness drives the shipped rules against allow/forbid fixtures through the pinned omp binary's real TTSR matching pipeline and asserts trigger/no-trigger per case, covering R4, R5, and R8 for every family, plus a guard that the shipped rule names do not shadow bundled rules.
- R10. A live omp session dogfood confirms end-to-end delivery: a write carrying a forbidden comment yields a `<system-reminder reason="rule_violation">` block prepended to the tool result, and a write carrying only allowed patterns yields none. This is a manual host observation, not an automated gate.

### Key Flows

- F1. Violation reminder
  - **Trigger:** The agent streams an edit/write tool call whose per-file snapshot contains a forbidden comment.
  - **Steps:** TTSR matches the family rule's `condition` against the snapshot for that file's path; `interruptMode: never` means no abort; within one matching batch a rule attaches to exactly one sibling tool call, so a turn writing several violating files of one family yields one reminder on the first file; when that tool result is produced, the rendered rule reminder is prepended to the result content.
  - **Outcome:** The file may briefly hold the comment, and the model is told in-band to remove it — the rule body directs it to sweep every file touched this turn (per R2), which covers the siblings the batch did not flag. Covers R2, R4.
- F2. Allowed content passes
  - **Trigger:** The agent writes a file containing only allowed patterns (shebang, BDD steps, linter directives, URLs).
  - **Steps:** No `condition` matches; nothing is prepended; the turn proceeds untouched.
  - **Outcome:** Zero reminders for compliant writes. Covers R4, R5.

### Acceptance Examples

- AE1. Covers R4. Given the hash rule, when the agent writes a Python file containing `# TODO: fix later`, then the rule triggers and the reminder is prepended.
- AE2. Covers R4. Given the hash rule, when the agent writes a shell script whose only comment is `#!/usr/bin/env bash`, then nothing triggers.
- AE3. Covers R4. Given the hash rule, when the agent writes a Python test whose only comments are `# given`, `# when`, `# then`, then nothing triggers.
- AE4. Covers R4. Given the C-family rule, when the agent writes a TypeScript file containing `// @ts-ignore`, then nothing triggers.
- AE5. Covers R5. Given the C-family rule, when the agent writes a TypeScript file containing `const url = "https://example.com";`, then nothing triggers.
- AE6. Covers R8. Given the Python docstring rule, when the agent writes a Python module starting with a `"""` docstring, then the rule triggers.
- AE7. Covers R3. Given `ttsr.repeatMode: after-gap`, when a rule has fired and 10 further turns complete, then a new violation in the same session triggers that rule again.
- AE8. Covers R4. Given the C-family rule, when the agent writes a Go file containing `//go:build linux` or `//nolint`, then nothing triggers.
- AE9. Covers R5. Given the C-family rule, when the agent writes a CSS file containing `background: url(//cdn.example.com/x.png);`, then nothing triggers.
- AE10. Covers R8. Given the Python docstring rule, when the agent writes a Python file whose only triple-quoted string is an assigned constant such as `QUERY = """..."""`, then nothing triggers.
- AE11. Covers R8. Given the Python docstring rule, when the agent writes a Python function whose body holds a bare `"""..."""` string statement, then the rule triggers — the accepted false-positive class, pinned so it is deliberate.

### Scope Boundaries

- Publishing as an omp plugin or marketplace package, and contributing upstream as an omp builtin rule, are excluded; the delivery surface is personal user rules only (KD1).
- Mid-stream interrupt-and-retry semantics are excluded; all rules use `interruptMode: never` (KD2).
- The original's `AgentMemoFilter` is not ported: it exists in the original's source but is never wired into its `apply_filters`.
- The original's `--prompt` custom-message flag has no counterpart: the TTSR rule body is the message.
- An `astCondition`-based detector is excluded as infeasible (see Problem Frame).
- Changing `ttsr.repeatGap` from its default of 10, and per-rule repeat policies (which TTSR does not support), are out of scope.

---

## Planning Contract

### Key Technical Decisions

- KTD1. **The fixture test drives the pinned omp binary's real TTSR pipeline.** The harness invokes `omp ttsr test --rule <file> --file <fixture> --source <source> --tool <tool> --path <name> --json` and asserts on the JSON `triggered`/`notTriggered` arrays, instead of re-implementing regex evaluation in bun or grep. Engine fidelity is structural: condition compilation, inline-flag translation, scope gating, and the registration compile-check all run production code paths. Smoke-verified on the installed 17.2.12 binary with a prototype C-family rule: trigger, no-trigger, exception, and scope-gate cases all behaved as designed. Note: `--json` mode always exits 0, so assertions read the JSON, not the exit code. (session-settled: user-approved — chosen over a bun/grep re-implementation of the matcher: re-implementation can go green while omp behaves differently.) Cites R9.
- KTD2. **Shared exception alternations, embedded per family.** BDD keywords match as prefixes followed by whitespace or end-of-line (the original's whole-body equality would flag real steps such as `# given a logged-in user`); directive prefixes replicate the original's boundary-less `starts_with` (so `# warning:` stays allowed, matching the original); the Go prefixes `go:` and `nolint` extend the catalog (user-confirmed deviation); and the same alternation applies uniformly to all six families, which is slightly more permissive than the original for OCaml and HTML comments, where the original exempts nothing. (session-settled: user-approved for the Go extension and BDD relaxation — chosen over strict verbatim parity: the original's Go gap would fire on `//go:build` in nearly every tagged Go file.) Cites R4.
- KTD3. **Marker anchoring and family secondary syntaxes.** Line-comment markers match at line start or after whitespace; `//` additionally must not follow `:` or `(` (R5's scheme and protocol-relative exclusions); `#` requires the line-start-or-whitespace anchor, which excludes URL fragments and Ruby string interpolation. Family condition arrays also carry the secondary syntaxes the original's grammars capture: the dash family adds `/* */` for SQL and `{- -}` for Elm, Lua's `--[[ ]]` is already covered by the `--` line match, and CSS stays in the C-family where only its block condition can fire in practice. Exact patterns are directional sketches in the High-Level Technical Design; the U3 fixtures pin the final behavior. Cites R5, R6, R7.
- KTD4. **The docstring rule anchors on line-initial bare triple quotes.** `^[ \t]*(?:"""|''')(?!\s*(?:DIRECTIVE|BDD))\s*` in multiline mode matches module/class/function docstrings and any other bare string statement while applying KTD2's shared exceptions without backtracking through leading whitespace, and cannot match assignments because code precedes the quotes there. The residual false positive — bare triple-quoted statements outside docstring position — is accepted and pinned by AE11. (session-settled: user-approved — chosen over attempting positional detection or dropping the docstring family: regex cannot express the original's positional query, and a reminder per gap window is the designed cost.) Cites R4, R8.
- KTD5. **Rule names use the `comment-<family>` namespace.** None of the 27 bundled names (`go-*` ×8, `rs-*` ×6, `ts-*` ×13) intersects it, and the U3 harness asserts on every CI run that no bundled rule carries one of the six shipped names (via `omp ttsr list --json` provider fields on the locked binary), so a future omp release that adds a colliding bundled rule fails CI instead of silently shadowing. Cites R1.
- KTD6. **Rule files ship managed-readonly.** Each file carries the `readonly_` attribute (`readonly_comment-c-family.md` deploys as `~/.omp/agent/rules/comment-c-family.md`, mode 0444), matching the repo's ownership rule: omp reads rules and never writes them, so they stay managed-readonly like `models.yml` and `mcp.json`. Files are plain markdown, not templates — no rendering, no secrets. Cites R1.
- KTD7. **`ttsr.repeatGap` stays undeclared.** The provisioner owns only declared paths, so an undeclared `repeatGap` leaves any hand-set host value in place; no managed host holds such an override today, and the alternative (declaring `10` explicitly) would make the data own a value the schema already defaults. A comment on the new `agents.yaml` entry records the deliberate omission. Cites R3.
- KTD8. **Rule bodies carry a whole-turn sweep instruction.** TTSR folds one reminder per rule per matching batch onto the first sibling tool call, so the body tells the model to check every file it touched this turn. This is content, not mechanism: it lives in each rule's markdown body alongside the bundled-style Why/Examples/Exceptions sections. (session-settled: user-approved — chosen over flagging only the first file: multi-file turns would otherwise leave sibling violations unremarked for a whole gap window.) Cites R2, F1.

### High-Level Technical Design

Two structures carry the plan: the per-family condition grammar and the test pipeline.

**Condition grammar (directional sketches — U3 fixtures pin final behavior).** Two shared alternations, embedded per family per KTD2:

```text
DIRECTIVE = @?(?:type:|noqa|pyright:|ruff:|mypy:|pylint:|flake8:|pyre:|pytype:|
              eslint-disable|eslint-ignore|prettier-ignore|ts-ignore|ts-expect-error|
              clippy:|allow|deny|warn|forbid|go:|nolint)        # case-insensitive, no trailing \b
BDD       = (?:given|when&then|when|then|arrange|act|assert)(?:\s|$)      # case-insensitive prefix
```

| Family rule | `condition` sketches (TTSR translates leading flag groups into JS flags — combined groups such as `(?im)` work, probe-verified on the locked binary; whole-pattern `(?i)` is safe because the comment markers are caseless) |
| --- | --- |
| `comment-c-family` | `(?im)(?:^|(?<=\s))(?<![:(])//(?!\s*(?:DIRECTIVE\|BDD))\s*` and `(?is)/\*(?!\s*(?:DIRECTIVE\|BDD)).*?\*/` |
| `comment-hash` | `(?im)(?:^|(?<=\s))#(?!!)(?!\s*(?:DIRECTIVE\|BDD))\s*` |
| `comment-dash` | `(?im)(?:^|(?<=\s))--(?!\s*(?:DIRECTIVE\|BDD))\s*`, plus `(?is)/\*(?!\s*(?:DIRECTIVE\|BDD)).*?\*/` (SQL) and `(?is)\{-(?!\s*(?:DIRECTIVE\|BDD)).*?-\}` (Elm) |
| `comment-html` | `(?is)<!\-\-(?!\s*(?:DIRECTIVE\|BDD)).*?\-\->` |
| `comment-ocaml` | `(?is)\(\*(?!\s*(?:DIRECTIVE\|BDD)).*?\*\)` |
| `comment-python-docstring` | `(?m)^[ \t]*(?:"""\|''')(?!\s*(?:DIRECTIVE\|BDD))\s*` |

The C-family line sketch preserves the smoke-verified TTSR condition shape while adding KTD3's line-or-whitespace anchor; all six sketches apply KTD2's shared exception alternation and are pinned by U3 fixtures at implementation time.

**Test pipeline.** Each fixture file under `.ci/fixtures/comment-checker/<family>/` is named `pass-*` or `trigger-*`; the driver runs it through `omp ttsr test` with the scenario's source, tool, and path, then asserts `triggered` is empty for `pass-*` and non-empty for `trigger-*`. The matrix covers every declared scope alias, both edit/write tool streams, and negative text/thinking streams. A scope-gate case feeds a violating fixture with a non-matching `--path` extension and asserts no trigger. The shadow guard runs `omp ttsr list --json` and asserts no rule with provider `builtin-defaults` carries any of the six shipped names.

### Assumptions

- A1. A resumed session restarts each fired rule's gap clock: omp persists injected rule names, not turn age, and `restoreInjected()` records each restored rule at message-count zero. Accepted — the effect is at most one reminder per rule per 10 newly completed turns after a resume.
- A2. User rules load from the active native agent directory only: named `--profile` sessions and `PI_CODING_AGENT_DIR` overrides do not read `~/.omp/agent/rules/`. Accepted — the managed setup uses the default directory.
- A3. No managed host holds a hand-set `ttsr.repeatGap` override; if one ever exists it persists (KTD7).
- A4. The rules tree deploys to containers and to both managed OSes (linux, darwin) as inert or live markdown; no host gating is added, matching today's ungated omp config deployment.

### Sequencing

U1 (rule files) lands first and is independently useful — omp loads the rules on the next apply. U2 (settings leaf) is independent and can land in any order. U3 (test harness) depends on U1's shipped rule files and fixtures deriving from the final conditions.

---

## Implementation Units

### U1. Comment-family TTSR rule files

- **Goal:** Six managed-readonly TTSR rule files exist under `dot_omp/private_agent/rules/`, one per comment-syntax family, each registering cleanly under omp's native provider.
- **Requirements:** R1, R2, R4, R5, R6, R7, R8 (KTD2–KTD6, KTD8; product decisions KD1–KD4, KD6 via their `Governs` links). Realizes F1 (the rule-side match, no-abort, and prepend steps plus the sweep instruction its Outcome names) and F2 (the no-match path).
- **Dependencies:** None.
- **Files:**
  - `dot_omp/private_agent/rules/readonly_comment-c-family.md` (create)
  - `dot_omp/private_agent/rules/readonly_comment-hash.md` (create)
  - `dot_omp/private_agent/rules/readonly_comment-dash.md` (create)
  - `dot_omp/private_agent/rules/readonly_comment-html.md` (create)
  - `dot_omp/private_agent/rules/readonly_comment-ocaml.md` (create)
  - `dot_omp/private_agent/rules/readonly_comment-python-docstring.md` (create)
- **Approach:**
  1. Frontmatter per file: one-line `description`, the family's `condition` list from the High-Level Technical Design sketches — U3's fixtures derive from these conditions and pin any needed adjustments (KTD3) — `scope` with the R7 extension globs on `tool:edit`/`tool:write` only, `interruptMode: never`.
  2. Body per file, following the bundled shape (imperative opening, Why, violating/compliant examples, Exceptions) plus the KTD8 whole-turn sweep instruction.
  3. Plain static markdown with the `readonly_` attribute; no `.tmpl`, no frontmatter templating, no secrets (KTD6).
- **Patterns to follow:** omp's bundled rules (`packages/coding-agent/src/discovery/builtin-rules/*.md` in `can1357/oh-my-pi`, for example `rs-box-leak.md`, `ts-no-deprecated-leftovers.md`) for frontmatter and body shape; the repo's `dot_omp/private_agent/` attribute conventions for `readonly_` naming.
- **Test scenarios:** The behavioral coverage for these files is the U3 fixture matrix, which runs each shipped rule through the real pipeline — per family: a forbidden-comment trigger case, the R4 allow-list cases (shebang, BDD, directives including `//go:build` and `//nolint`), the R5 URL cases, and the R8 docstring cases (AE6, AE10, AE11). Malformed frontmatter cannot ship silently: U3's per-condition coverage gate fails when any declared condition never appears in a matched set, which catches both uncompilable conditions and unexercised ones.
- **Verification:** Each rule file registers and behaves per the U3 harness; the deployed names carry the `comment-` namespace (KTD5); a source-tree listing shows exactly the six files with `readonly_` names and no other new tree content.

### U2. `ttsr.repeatMode` settings declaration

- **Goal:** Every apply asserts `ttsr.repeatMode: after-gap` into omp's live `config.yml`, with `repeatGap` deliberately left omp-owned at its default.
- **Requirements:** R3 (KD5 via its `Governs` link; KTD7).
- **Dependencies:** None.
- **Files:**
  - `.chezmoidata/agents.yaml` (modify — one scalar leaf under `agents.omp.settings`, placed beside the other non-model literal paths, with a comment recording that `ttsr.repeatGap` is intentionally undeclared per KTD7)
- **Approach:** Add `ttsr.repeatMode: after-gap` as a flat dotted path. No provisioner, validator, or script changes: the settings validator's path grammar and value charset both admit the entry, the parent-namespace rule is satisfied because no other `ttsr.*` path is declared, and the provisioner's per-key `omp config set` loop is fully generic.
- **Patterns to follow:** The `memory.backend: mnemopi` precedent (scalar leaf, no provisioner change) and the placement convention of keeping non-model literal paths together.
- **Test scenarios:**
  - Rendering `.chezmoiscripts/70-agents/run_after_config-omp-settings.sh.tmpl` with the scratch `op` stub produces a script whose embedded declared map contains a `"ttsr.repeatMode": "after-gap"` entry (the generic per-key loop turns it into an `omp config set` call at runtime, which the reconcile scenario below proves).
  - The existing `.ci/test-omp-agent-reconcile.sh` passes against the re-rendered scripts with its count assertion auto-derived from the declared map (no edit to that test).
- **Verification:** Isolated render shows the new assertion; the reconcile test passes unmodified; `git diff --check` is clean.

### U3. Fixture test harness and CI wiring

- **Goal:** CI proves, on every run, that the shipped rules trigger on forbidden comments and stay silent on allowed content — evaluated by the pinned omp binary's own TTSR pipeline — and that the shipped names never shadow bundled rules.
- **Requirements:** R9 (KTD1, KTD5; AE1–AE6, AE8–AE11 as fixture cases; AE7 is session-runtime behavior and stays with the R10 dogfood).
- **Dependencies:** U1.
- **Files:**
  - `.ci/test-omp-comment-rules.sh` (create — bash driver, `set -euo pipefail`, scratch under `${XDG_RUNTIME_DIR:-$HOME/.cache}` with a cleanup trap, shellcheck-clean)
  - `.ci/fixtures/comment-checker/<family>/pass-*` and `trigger-*` files (create — six families, cases per the test scenarios below)
  - `.github/workflows/ci.yml` (modify — one added step in the `omp-agent-integration` job's run block, after the locked-omp install; no `delivery` change because the job is already in the terminal-success needs list. The step invokes the locked binary through an explicit path or registers `$RUNNER_TEMP/bin` on `PATH` itself: today the only PATH registration in the job lives in the unrelated chezmoi-install step, and relying on that ordering strands the harness if steps are reordered)
- **Approach:**
  1. Driver iterates the fixture tree and invokes `omp ttsr test --rule <source rule> --file <fixture> --source <source> --tool <tool> --path <fixture basename> --json`, asserting the JSON arrays rather than exit codes because `--json` always exits 0 (KTD1). Trigger coverage exercises both `tool:write` and `tool:edit`; source-negative coverage exercises `text` and `thinking` streams.
  2. Shadow guard: `omp ttsr list --json` from a clean scratch cwd; assert no entry with provider `builtin-defaults` carries any of the six shipped names.
  3. The driver derives its rule-file set from the source tree (`dot_omp/private_agent/rules/*.md`) rather than a hardcoded list, so adding a family later extends coverage automatically; fixture expectations stay hardcoded because their independence is the assertion. Assertions must stay name-agnostic: in isolated mode omp derives the rule name from the file basename, so the tested name carries the `readonly_` prefix while the deployed name does not — the shadow guard asserts against the six deployed names, which are hardcoded for exactly that reason.
- **Execution note:** This is mostly test tooling; prefer running the harness itself as the proof over adding meta-tests for the driver.
- **Patterns to follow:** `.ci/test-omp-agent-reconcile.sh` for scratch/stub/assertion structure; `.ci/lib/render-gate-helpers.sh` conventions where rendering is needed (rule files are static, so none is); the existing explicit-step wiring in the `omp-agent-integration` job.
- **Test scenarios:**
  - Fixture basenames always carry a real in-scope extension or basename for their family (`trigger-todo.py`, `pass-shebang.sh`, `trigger-block.ts`, the hash Dockerfile case as a literal `Dockerfile`), because `--path <fixture basename>` drives scope gating: a pass case outside its rule's scope would assert vacuously.
  - Pass cases map to the family whose condition could actually match them: shebang-only → hash (AE2); fragment `page.html#section` → hash; scheme URL (AE5) and protocol-relative `url(//…)` (AE9) → C-family; directive-only and BDD-only → all six families, each rendered in the family's own marker (for example `<!-- eslint-disable -->`, `(* noqa *)`, `-- given`, and `"""given a user"""`), which pins KTD2's uniform-exception deviation; plus an in-scope empty-file case per family.
  - Per family, `trigger-*`: a file containing one forbidden comment of that family's syntax triggers (AE1, AE6 shapes); the line-comment families also include marker-only comments (`//`, `#`, `--`) so empty comments cannot evade detection; for the dash family this includes a SQL `/* ... */` case and an Elm `{- -}` case, pinning the KTD3 secondary syntaxes.
  - Docstring family: assigned-constant pass (AE10) and bare-statement trigger (AE11), pinning the accepted false positive as deliberate.
  - Boundary semantics: `# warning: explain` passes and `# warn users` passes, matching the original's boundary-less `starts_with` (KTD2); C-family trigger and pass fixtures prove `//` starts only at line start or after whitespace and that `https://`, string protocol-relative URLs, and `url(//…)` do not trigger.
  - Per-condition coverage: across the full fixture run, the driver collects every rule's `matched.regex` entries and asserts each condition declared in each shipped rule's frontmatter appears in at least one matched set. Probe-verified on the locked binary: a single uncompilable condition among valid ones is silently dropped at registration (only an all-conditions-bad rule errors), so this coverage gate — not registration — is what fails loudly on a dead or typo'd condition.
  - Scope matrix: one forbidden fixture per R7 extension alias or basename runs through the corresponding family rule with that alias as `--path`; php, svelte, and Python cases assert both of their required family rules trigger. A violating C-family fixture evaluated with `--path fixture.py` does not trigger, while representative violations under both `tool:write` and `tool:edit` trigger and the same content under `text` and `thinking` does not.
  - Shadow guard: `omp ttsr list --json` shows no `builtin-defaults` rule named `comment-c-family`, `comment-hash`, `comment-dash`, `comment-html`, `comment-ocaml`, or `comment-python-docstring`.
- **Verification:** The harness exits 0 against the shipped rules locally against the host's installed omp (the driver fails loudly when the host binary's version differs from the `.chezmoidata/releases.json` lock, so a local green predicts CI green) and in CI against the locked binary; a deliberate fixture perturbation (flip one `pass-` expectation) makes it fail, proving the gate fires; shellcheck reports no findings on the new script.

---

## Risks & Dependencies

| Risk | Mitigation |
| --- | --- |
| Locked-CLI surface drift at a `releases.json` omp bump: flag shapes of `omp ttsr test --rule/--file/--source/--tool/--path/--json`, the `--json`-always-exits-0 contract, the `triggered`/`notTriggered` JSON fields, and the `builtin-defaults` provider string in `omp ttsr list --json` are all upstream-owned. | Drift lands loudly on the bump PR, not on silent green: a shape change that empties `triggered` fails every `trigger-*` case, and a JSON shape change errors the driver. KTD5's shadow guard pins the provider field on every run. The Goal Capsule stop condition is the escalation path if the surface is genuinely removed. |
| TTSR frontmatter-semantics drift: inline-flag translation, the `tool:edit(*.py)` scope grammar, and the registration compile-check are re-interpreted by upstream on every omp bump with no code change here. | The U3 harness exercises those production parse paths on every CI run against the locked binary, so a semantics change fails the bump PR instead of silently re-interpreting deployed rules. |
| CI wiring fragility: the locked omp binary currently reaches `PATH` only through the unrelated chezmoi-install step. | The U3 step invokes the locked binary through an explicit path (or registers `PATH` itself), so step reordering cannot strand the harness with `omp: command not found`. |
| `ttsr.repeatMode: after-gap` is global: reminder frequency rises for all 27 bundled rules in every session, and per-rule repeat policies do not exist, so a partial revert is impossible. | Full reversal is deleting the single `agents.yaml` leaf — no code change. KD5 records the accepted cost. |

---

## Verification Contract

| Gate | Command / check | Applies to | Done signal |
| --- | --- | --- | --- |
| Fixture harness | `.ci/test-omp-comment-rules.sh` (locally against the host's installed omp, with a lock-version guard; in CI against the locked binary) | U1, U3 | Exit 0; perturbation check fails the harness when an expectation is flipped |
| Settings render | Render `.chezmoiscripts/70-agents/run_after_config-omp-settings.sh.tmpl` with the AGENTS.md scratch `op` stub recipe | U2 | Rendered script asserts `ttsr.repeatMode after-gap`; render exits 0 |
| Reconcile regression | `.ci/test-omp-agent-reconcile.sh` against re-rendered scripts, unmodified | U2 | Passes; its declared-map count auto-includes the new key |
| Lint/hygiene | `git diff --check`; shellcheck on the new `.ci` script (CI lints every `.ci/*.sh`) | U3 | No findings |
| CI workflows | `ci.yml` and `render-dotfiles.yml` watched to terminal success after push | All | Both green |
| Live dogfood | R10: in a real omp session, a write with a forbidden comment yields a prepended `<system-reminder reason="rule_violation">`; an allowed-only write yields none; a second violation after 10 completed turns reminds again (AE7) | U1, U2 | User observes and reports; never performed silently by the agent |

---

## Definition of Done

- U1, U2, U3 are landed and each unit's Verification line holds.
- Every Verification Contract gate is green, including the harness perturbation check.
- The Product Contract is intact as amended by the preservation note: R4's catalog carries the Go extension, R5 covers protocol-relative URLs, R8 states the docstring anchor and its accepted false positive, and F1 states per-batch single-reminder semantics.
- The R10/AE7 dogfood observation is reported by the user from a live session.
- The diff contains no abandoned-attempt artifacts: prototype rules, scratch fixtures, or alternate harness sketches from planning are removed or live outside the repository.

---

## Sources & Research

- omp upstream (`can1357/oh-my-pi`): `docs/rulebook-matching-pipeline.md` (providers, precedence, frontmatter, scope grammar), `docs/ttsr-injection-lifecycle.md` (matching, per-batch bucketing, repeat/restore semantics), `packages/coding-agent/src/discovery/builtin-rules/*.md` (27 bundled rules, all `interruptMode: never`), `packages/coding-agent/src/cli/ttsr-cli.ts` (isolated rule test and JSON surfaces), `packages/coding-agent/src/config/settings-schema.ts` (`TtsrSettings`, `ttsr.*` keys).
- Original (`code-yeongyu/go-claude-code-comment-checker`): `src/language.rs` (31 languages, 42 extension aliases), `src/filters.rs` (BDD/directive/shebang catalog; `AgentMemoFilter` unused by `apply_filters`), `README.md`.
- This repo: `.chezmoiscripts/70-agents/run_after_config-omp-settings.sh.tmpl` (per-key assertion), `.chezmoitemplates/omp-settings-validate.tmpl` (render-time gates), `.ci/test-omp-agent-reconcile.sh` (declared-map-derived assertions), `.ci/lib/render-gate-helpers.sh`, `.github/workflows/ci.yml` (`omp-agent-integration` job), `.chezmoiignore` (container gate does not cover `.omp/agent/rules`).
- Live host verification during planning: installed omp 17.2.12 ran `omp config list` (`ttsr.repeatMode = once (once|after-gap)`, `ttsr.repeatGap = 10`), an isolated-profile `omp config set ttsr.repeatMode after-gap` succeeded, and a prototype C-family rule passed trigger/no-trigger/exception/scope-gate smoke cases through `omp ttsr test --rule`.
