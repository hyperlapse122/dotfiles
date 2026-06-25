# Rebase — reference

Resolve conflicts by **intent, not reflex**:

- **Regenerated / generated artifacts** (lockfiles, build outputs, sequence-numbered
  migrations, generated configs): take `main`'s version, then re-run the generator on top
  so your additions reproduce on the new base.
- **Hand-written code**: review both sides and merge intentionally. **MUST NOT** blindly
  pick `--ours` or `--theirs` — that silently drops one side's work.

**Note**: during a rebase, Git's `--ours` / `--theirs` are **reversed** vs. merge.
`--ours` is `main` (the rebase target being replayed onto); `--theirs` is the feature
commit being applied.

Wrong side / wrong direction: `git rebase --abort` and restart. **MUST NOT** continue.
