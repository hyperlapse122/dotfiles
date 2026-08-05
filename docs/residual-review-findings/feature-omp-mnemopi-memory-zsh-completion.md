# Residual Review Findings

Source run: `ce-code-review mode:agent plan:docs/plans/2026-08-05-004-feat-omp-mnemopi-memory-zsh-completion-plan.md`,
branch `feature/omp-mnemopi-memory-zsh-completion`, 2026-08-05.

Reviewers: correctness, project-standards, testing, maintainability, security, performance, reliability, adversarial.
Coverage gap: the cross-model adversarial peer could not start — no `cursor-agent`, `codex`, `claude`, or `grok`
CLI exists on this host — so the in-process `adversarial-reviewer` ran as the documented fallback. Its agreement with
other in-context lenses is **not** independent corroboration.

Ten findings were applied on the branch (see the three commits). The items below are the actionable findings that
were deliberately **not** applied, plus the residual risks worth carrying forward. No tracker is declared for this
project in its instructions or in `.compound-engineering/config.local.yaml`, so this committed file is the durable
sink rather than filed issues.

## Not applied

- **P1 — `.github/workflows/ci.yml`: `Install locked chezmoi` is duplicated across jobs.**
  The new `omp-zsh-completion` job repeats the block already present in `omp-agent-integration`. The copy originally
  dropped the `sha256sum --check` verification; that regression **was** fixed, so the two are now behaviourally
  identical. The remaining duplication stands. The proper fix is a composite action
  (`.github/actions/install-locked-tool/action.yml`) parameterised by the `.chezmoidata/releases.json` tool key.
  Deferred because `.github/actions/` does not exist in this repo yet, the same block already appears three times
  before this change, and introducing that convention would modify an existing green job — a separate refactor,
  not part of enabling omp memory and a shell completion.

- **P2 — the completion install path is a literal in three files.**
  `~/.local/share/zsh/site-functions` appears independently in
  `.chezmoiscripts/70-agents/run_onchange_after_install-omp-zsh-completion.sh.tmpl`,
  `.ci/test-omp-zsh-completion.sh`, and `dot_config/zsh/dot_zshrc`. Relocating it later needs a synchronised
  three-file edit. Deliberately not tied together: the test's independently hardcoded path is exactly what proves a
  generator writing to the wrong directory fails the suite. Sharing one constant would make that assertion circular.
  The three languages involved (Go template, bash, zsh) also have no common constant mechanism here.

- **P2 — `.chezmoitemplates/omp-path-guard.sh.tmpl` extraction (from the simplification pass).**
  The `~/.local/bin` PATH prepend and the `command -v omp` soft-skip are near-duplicates of
  `.chezmoiscripts/70-agents/run_after_config-omp-settings.sh.tmpl`, and the repo has a real precedent for shared
  shell guards (`sudo-skip-guard.sh.tmpl`, `headless-guard.sh.tmpl`). Deferred: only the 5-line PATH block is truly
  identical — the two soft-skips differ in message and the settings script additionally guards on `jq` — so a shared
  template would need two parameters and a toggle to save five lines, while making each provisioning script less
  self-contained during debugging.

## Residual risks carried forward

- **Plugin-driven completion drift bypasses the version fingerprint.** The onchange trigger is the locked omp version
  plus a render-time availability flag. If an omp plugin adds commands without an omp version bump, the installed
  `_omp` goes stale until the next bump. Accepted: completions degrade to missing entries, never to breakage.
- **The revived `_buf` completion is untested.** Putting `~/.local/share/zsh/site-functions` on `$fpath` activates the
  `_buf` file that `.chezmoiexternals/dev-tools.toml` has been depositing there since before this change, and which
  has never loaded. This is the intended behaviour and the reason that file is deployed, but it is a real behaviour
  change on the next shell.
- **FILE-phase-before-`run_after_` ordering is assumed, not proven.** The generator relies on chezmoi installing the
  `[omp]` external before `70-agents/` scripts run. The render-time availability flag now makes a wrong assumption
  self-healing on the following apply rather than permanent, but the ordering itself was not independently verified.
- **No test drives chezmoi's real onchange state tracking.** `.ci/test-omp-zsh-completion.sh` proves the rendered
  script's behaviour, not that chezmoi records an exit-0 soft-skip as a completed fingerprint. The availability flag
  is the mitigation; its interaction with chezmoi's state file is reasoned, not exercised.
- **Signal handling is untested.** The `trap 'exit 129|130|143'` handlers are not exercised by any case; testing a
  signal race would be flaky for little gain.
- **CI wall-clock contribution is unmeasured.** The new job runs in parallel with the Rust and TypeScript jobs and is
  very unlikely to be the critical path, but no CI history backs that.
- **mnemopi processing crosses a provider boundary.** Storage is local; LLM-backed extraction and consolidation use
  the configured `tiny` role, a cloud model. This is now disclosed in `.chezmoidata/agents.yaml` next to the setting.
  Set `mnemopi.llmMode: none` to keep processing on-device.
