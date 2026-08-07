# Residual Review Findings — feedback sweep resolution

Source run: branch `chore/resolve-feedback-sweep-open-items`, head `316e85f`.
Plan: `docs/plans/feedback-sweep-plan.md`.

Two review passes ran over this branch: `ce-code-review mode:agent` across the whole
diff, then a focused adversarial `security-reviewer` pass over the guard's tokenizer
after that first review's fix added new parsing code to a security boundary.

Everything actionable that the branch **does** fix is in its commits. This file records
what it does not.

## Filed as issues

All four are pre-existing defects in `dot_local/share/omp-plugins/plugins/unmanaged-repo-guard/src/triggers.ts`.
None was introduced by this branch; each needs a design decision of its own, which is why
none was folded into a change that was already hardening the same file.

Every command in them was verified on both sides — the argv bash really builds, via an
argv-printing fake `gh` on `PATH`, and the guard's own `classify()` output. No network
call and no real `gh`/`glab` invocation was made.

- **P1** · `triggers.ts:448-476` · [#186](https://github.com/hyperlapse122/dotfiles/issues/186) —
  `ARGV_PREFIXES` skips a recognised prefix but not its options, so `env -u FOO gh issue create …`
  resolves its head to `-u` and is dropped. `env -C` additionally relocates the working
  directory the guard's `cd`-tracking would have used.
- **P1** · `triggers.ts:598-607` · [#187](https://github.com/hyperlapse122/dotfiles/issues/187) —
  an interpreter's `-c` body is never scanned, and a captured heredoc body is not re-split
  on decoded whitespace.
- **P2** · `triggers.ts:608-611` · [#188](https://github.com/hyperlapse122/dotfiles/issues/188) —
  argv-forwarding wrappers (`xargs`, `timeout`, `nice`, `stdbuf`, `setsid`) drop the segment
  silently.
- **P2** · `triggers.ts:610-611` · [#189](https://github.com/hyperlapse122/dotfiles/issues/189) —
  `cliIsIssueWrite` reads positions from a word list that strips flag tokens but keeps their
  values, so a value-taking flag before the subcommand shifts every positional.

## Unresolved upstream, deliberately not filed

- **P0 residual half of [#168](https://github.com/hyperlapse122/dotfiles/issues/168)** — the
  instruction core's precedence rule over the skill-level tracker-defer fallback chain.

  The repo-owned half is already enforced: the merged `unmanaged-repo-guard` plugin intercepts
  every `tool_call` by shape with no branch on which skill produced it, and this branch adds a
  real-runtime proof that it holds on omp's default MCP mounting as well as the direct one. The
  remaining half is a change to `tracker-defer.md`, which lives in a read-only plugin cache
  outside this repository and belongs to a project this user does not manage.

  Under the very rule this work strengthens, an unattended run must not file into or comment on
  that tracker without explicit user confirmation, and no user was present. #168 therefore stays
  open and the pull request references it with `Refs`, never `Closes`. Filing upstream is a
  deliberate human decision.

## Retracted during the run

- A commit on this branch claimed a fail-open bypass via omp's `xd://` device transport and added
  a `classify` branch for it. **That claim was wrong** and the code was removed in `b39df7d`.
  Tracing every `toolName` the handler receives showed omp fires the hook twice for a device
  write — once for the outer `write`, then again for the expanded `mcp__<server>_<tool>` — so the
  pre-existing `mcp__` branch already covered it. The end-to-end scenario the investigation
  produced was kept, because it pins that omp runtime behaviour; the redundant code was not.

## Advisory, not actionable

- Byte-level divergences between the guard's ANSI-C decode and bash are now nil across a
  33-body fidelity sweep, but that sweep is a one-off performed during this run rather than a
  committed test. The committed suite asserts the specific shapes that were exploitable.
- No automated check asserts the instruction-core body text. Recorded as assumption A5 in the
  plan; #168 classes the idea as advisory.
