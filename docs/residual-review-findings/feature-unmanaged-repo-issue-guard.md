# Residual review findings — feature/unmanaged-repo-issue-guard

Source run: `lfg` pipeline for [issue #168](https://github.com/hyperlapse122/dotfiles/issues/168).
Change: a repo-owned omp `tool_call` extension that mechanically enforces the
unmanaged-repository issue-filing gate, per
`docs/plans/2026-08-05-006-feat-unmanaged-repo-issue-guard-plan.md`.

Review coverage: `ce-simplify-code` (code-reuse, code-quality, efficiency) then
`ce-code-review mode:agent` with nine personas — correctness, project-standards,
testing, security, reliability, maintainability, agent-native, api-contract, and
adversarial. Every persona ran as a separately dispatched in-process context.

**Independence caveat.** The cross-model adversarial peer did **not** run: no
sanctioned cross-model route is configured on this host, so the in-process
adversarial reviewer ran as the documented fallback. `independence_verified` is
false for that lens, and where two personas converged below, the corroboration
is across separate in-process contexts only, never across model providers.

The `security` persona's structured yield failed schema validation; its findings
were recovered verbatim from its transcript and are included.

## Fixed in this change

Recorded because the reviews found real defects, not just polish. Four confirmed
classifier bypasses were found **and each was reproduced before fixing**:

- **P0** — `(gh issue create …)` / `{ gh issue create …; }` grouping punctuation
  made the argv head `(gh`, so the segment was skipped and no fallback fired.
- **P0** — a heredoc followed by a shell operator on the same line
  (`bash <<'EOF' && echo done`) stranded the body on the wrong segment, so the
  interpreter branch never saw it.
- **P1** — an interpreter flag colliding with a body-flag name (`bash -m <<EOF`,
  `python3 -b <<EOF`) made an executable stdin body look like inert issue data.
  Fixed by deleting the body-flag heuristic entirely: an interpreter's stdin is
  always executable, and a body attached to a `gh`/`glab` segment is never
  rescanned because that segment already classifies by its subcommand.
- **P0** — `cd /other && gh issue create` with no `--repo` resolved `origin`
  from the *outer* cwd, so a managed outer checkout waved through a write that
  the real shell files into an unmanaged repo. This is exactly the invocation
  shape `tracker-defer.md` documents ("Repo defaults to the current repo"), so
  it defeated the guard on its own motivating path. Fixed by tracking literal
  `cd`/`pushd` targets and failing closed on any target that cannot be resolved
  literally.

Also fixed: an unbounded `git remote get-url` subprocess on the tool-call path;
a per-call leaked timer; a config-load failure that silently left every issue
write unguarded (now registers a fail-closed handler); an attended-path reason
string that told the agent to ask-then-file when no consent channel exists; a
stale MCP tool name (`mcp__glab_issue_note_create` → `mcp__glab_issue_note`);
an unvalidated identity in the verdict cache key; a fork parent that failed
validation being treated as "not a fork"; unbounded CLI stderr reaching the
agent-facing reason string; and a bracketed-IPv6 `origin` URL being garbled.

One reported **P0 was a false positive** and is recorded as such: redirection
operators (`2>&1`, `&>`, `>&`) were claimed to defeat detection. Reproduced and
disproved — those commands classify correctly. `operatorLength` was hardened
anyway so a bare `&` adjacent to a redirection is not read as a control operator.

## Residual Review Findings

- **P1 — CI never exercises omp's own extension resolution.**
  `.ci/test-unmanaged-repo-guard-real.sh:110-119`, `.github/workflows/ci.yml`.
  Converged independently across the `testing` and `adversarial` lenses.
  U8 step 4 — the only assertion that drives a tool call through omp's real
  runtime and proves the block actually stops execution — needs a live model
  turn, and this repository's CI configures no model credentials, so it is
  skipped on every CI run. Green CI therefore proves install/enable/load, not
  runtime dispatch through the guard.
  *Partially mitigated here:* an unconditional step 3b now loads the installed
  raw `.ts` entry under Bun and asserts the single `tool_call` registration; the
  skip emits a `::warning::` annotation so the gap is visible in the Checks UI;
  and the plan's U8 "Detection limits" paragraph names the credential gate.
  *Not closed here:* fully closing it means provisioning a model credential as a
  CI secret, which is a user decision about secrets, not a change this run may
  make. Owner: human.

- **P1 — six byte-identical bash helpers duplicated across two render-gate
  tests.** `.ci/test-unmanaged-repo-guard-gates.sh:16-101` versus
  `.ci/test-mxm4-haptic-gates.sh:17-133` (`require_file`, `render`,
  `render_ignore`, `is_ignored`, `assert_gate`, `render_reconciler`).
  Raised by `code-reuse`, then re-raised by `maintainability` with a stronger
  fix than the one I rejected: extract into a shared lib but pass `repo_root`,
  `scratch`, and `chezmoi_bin` as explicit leading positional arguments, which
  defeats my dynamic-scope objection outright. Deferred rather than applied
  because it restructures an existing green test and introduces a new `.ci/lib/`
  convention — a design decision that deserves its own change, not a late edit
  inside a security fix. Nothing asserts the two copies stay identical, so they
  can drift. Owner: human.

- **P2 — ANSI-C `$'…'` quoting is mis-modelled by the tokenizer.**
  `dot_local/share/omp-plugins/plugins/unmanaged-repo-guard/src/triggers.ts`
  (`splitCommand` quote tracker). An escaped quote inside `$'…'` closes the
  tracked quote early and can leave a phantom quote open to EOF. In the one case
  traced this coincidentally sets `unparseable`, which routes to `fallbackScan`
  and still detects the write — so no bypass was constructed — but the quote-state
  model is objectively wrong and a differently-shaped input could mis-split
  without setting `unparseable`. Owner: human.

- **P2 — the guard emits no durable audit trail.** A block's only trace is the
  reason string inside that run's own transcript. There is no session-independent
  record, so a misfire (stale cache, wrong host resolution) is hard to diagnose,
  and a miss by the deliberately fail-open MCP name pattern is invisible.
  Logging on the block path was left out to keep the hot path allocation-free
  and avoid writing from a `tool_call` handler; revisit if the guard ever
  misfires in practice. Owner: human.

- **P2 — `identityFor` runs before the verdict cache is consulted.**
  `probe.ts` `probeOne`. A verdict cache hit still costs one bounded identity
  subprocess. Bounded and correct, just not free. Owner: downstream-resolver.

- **P3 — `splitCommand`'s load-bearing invariants are undocumented.**
  Its backslash rule (escapes honored inside double quotes, not single, matching
  bash) and the fact that command-substitution handling deliberately lives two
  functions away in `argvHead`'s `opaque` check are both unstated. A future
  editor of that ~200-line state machine has to re-derive them. Owner: human.

- **P3 — no test drives a subagent's own MCP-tool call through the real omp
  runtime.** KTD2's uniform-interception claim was verified empirically for a
  subagent's *bash* call and separately for an MCP tool arriving as its own
  `toolName`, but not for the composition of the two. Owner: human.

## Filing status

Each residual above is filed as a tracked issue against
`hyperlapse122/dotfiles`, linked inline below. The repository-management probe
this very change enforces was run first and returned
`viewerPermission: ADMIN`, so filing here is permitted under
`.chezmoitemplates/agents-instructions.tmpl:50`.

| Finding | Issue |
|---|---|
| CI never exercises omp's own extension resolution | [#171](https://github.com/hyperlapse122/dotfiles/issues/171) |
| Six byte-identical bash helpers duplicated | [#172](https://github.com/hyperlapse122/dotfiles/issues/172) |
| ANSI-C `$'…'` quoting mis-modelled | [#173](https://github.com/hyperlapse122/dotfiles/issues/173) |
| No durable audit trail | [#174](https://github.com/hyperlapse122/dotfiles/issues/174) |
| `identityFor` runs before the verdict cache | [#175](https://github.com/hyperlapse122/dotfiles/issues/175) |
| `splitCommand` invariants undocumented | [#176](https://github.com/hyperlapse122/dotfiles/issues/176) |
| No subagent MCP-route runtime test | [#177](https://github.com/hyperlapse122/dotfiles/issues/177) |

Originating PR: [#170](https://github.com/hyperlapse122/dotfiles/pull/170).
