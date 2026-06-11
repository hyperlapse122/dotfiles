# docs/

Reference documentation for this dotfiles repo. These files are for humans and
agents reading the repo — they are not consumed by bootstrap scripts or CI.

## Contents

| File | Purpose |
|---|---|
| [`chezmoi-migration.md`](./chezmoi-migration.md) | Migration map from the old dotbot layout to the current chezmoi model: path-mapping table, orchestrator ordering, ownership boundary, and first-boot contract |

## Conventions

- Every file here is a static reference document. Nothing in `docs/` is executed
  or symlinked by bootstrap.
- Keep docs in sync with `AGENTS.md` and the relevant directory `README.md`s.
  A structural change to the repo that affects how bootstrap works should update
  both the owning directory's `README.md` and any relevant doc here in the same
  commit.
