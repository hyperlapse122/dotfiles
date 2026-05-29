# packages/

Standalone TypeScript/JavaScript **leaf packages**. Each subdirectory is a
self-contained package with its own `package.json`, `tsconfig.json`, and
lockfile.

## What this is NOT

- **Not a Yarn workspace.** There is intentionally no root `package.json` and no
  `workspaces` field in this repo. A root manifest would turn the entire
  `~/dotfiles` checkout into a Yarn Berry project (the user-global
  `~/.yarnrc.yml` applies repo-wide) and litter the repo root with `.yarn/`,
  `.pnp.*`, and a root `yarn.lock`. Each package here is independent instead.
- **Not bootstrap-installed.** Unlike [`../crates/`](../crates/) (whose Rust
  binaries are `cargo install`'d into `~/.local/bin` during dotbot bootstrap),
  a library here ships nothing to install. `install.*.yaml` does not touch
  `packages/`, and dotbot does not link anything from it. Consumers install and
  build a package themselves.

## Layout

| Path | Package | Purpose |
|---|---|---|
| [`mxm4-haptic/`](mxm4-haptic/) | `@h82/mxm4-haptic` | Node/Bun client for the `mxm4-hapticd` daemon — sends MX Master 4 haptic waveforms over the daemon's AF_UNIX socket. Mirrors the portable client surface of [`../crates/mxm4-haptic/src/lib.rs`](../crates/mxm4-haptic/src/lib.rs). |

## Conventions

- **Package manager: Yarn Berry** (the repo-wide preferred manager). The
  user-global `~/.yarnrc.yml` hardening applies to every package here: exact
  version pinning (no `^`/`~`/ranges), a 1-week dependency cooldown gate
  (`npmMinimalAgeGate`), and disabled lifecycle scripts (`enableScripts: false`).
  Do not relax these. A leaf may set `nodeLinker: node-modules` in its own
  `.yarnrc.yml` to get a plain `node_modules/` tree (overriding only that key);
  everything else cascades from the user-global config.
- **`yarn.lock` is tracked** per package (lockfile convention, like the Rust
  `Cargo.lock` under `crates/`). `node_modules/`, `dist/`, and `.yarn/` are
  git-ignored (leaf-scoped patterns in the root `.gitignore`).
- **First install gotcha**: the user-global `enableImmutableInstalls: true`
  makes the very first `yarn install` (which must generate `yarn.lock`) fail.
  Use `yarn add <pkg>@<exact>` (a mutating command) or
  `yarn install --no-immutable` for the initial lockfile; subsequent
  `yarn install --immutable` runs are clean.
- **Private, not published.** These are local packages (`private: true`). The
  `@h82/` scope is a naming namespace only — nothing is published to a registry.
- Every package directory has its own `README.md`.

## Adding a new package

1. `mkdir packages/<name>` and add `package.json` (`name`, `private: true`,
   `"type": "module"`), `tsconfig.json`, and a leaf `.yarnrc.yml` if you need
   the `node-modules` linker.
2. Document the package in its own `README.md` and add a row to the layout table
   above.
3. Update the root [`AGENTS.md`](../AGENTS.md) Layout block and
   [`README.md`](../README.md) repo-structure table in the **same commit** (the
   repo's hard documentation-sync rule).
