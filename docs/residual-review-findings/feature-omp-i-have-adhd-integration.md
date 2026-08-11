# Residual Review Findings

- Review run: `20260811-120531-30a3fc66`
- Scope: `feature/omp-i-have-adhd-integration` at `0b73dc0`
- Source: local-aligned `ce-code-review` agent-mode review

## Unapplied finding

- P1 `.chezmoiscripts/70-agents/run_after_patch-i-have-adhd-extension.sh.tmpl:41` -- [Restore ADHD rules after compaction](https://github.com/hyperlapse122/dotfiles/issues/202). The OMP 17.2.12 fallback uses the full journal, so it can mistake compacted-away rules for live model context. Validation is degraded because the independent validator was unavailable. The issue carries the evidence and proposed compaction-aware replacement.
