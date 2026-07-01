# Plan 001: Add a CI pipeline that verifies the Rust crate, the TS workspace, and shell scripts

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat 7a12e58..HEAD -- packages/README.md .github/`
> If `packages/README.md` changed since this plan was written, compare the
> "Current state" excerpt against the live code before proceeding; on a
> mismatch, treat it as a STOP condition. `.github/` is expected to NOT exist yet.

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: LOW
- **Depends on**: none
- **Category**: dx
- **Planned at**: commit `7a12e58`, 2026-07-01

## Why this matters

This repo builds and tests real code — a Rust crate (`crates/mxm4-haptic/`, a
haptic daemon + two client binaries with ~30 unit tests) and a Yarn/Turbo
TypeScript workspace (`packages/`, three packages with real test suites) — plus
26 shell provisioning scripts. **None of it is verified automatically.** There
is no `.github/` directory and no CI of any kind. Worse, the docs already claim
CI exists: `packages/README.md` tells contributors that lint + format run "via
`../.github/workflows/lint.yml`", a file that does not exist. So a contributor
(or an agent executing another plan in this directory) trusts a gate that isn't
there. This plan adds a real GitHub Actions workflow that runs the checks the
project already defines, and corrects the stale doc reference so it points at
the workflow that now exists. The payoff is concrete: the hand-mirrored Rust↔TS
waveform tables are guarded by `packages/mxm4-haptic/test/drift-guard.test.ts`,
which only protects against drift if it actually runs on every push.

## Current state

- **No CI exists.** `git ls-files .github` returns nothing; there is no
  `.github/workflows/` directory anywhere in the repo.
- **The stale doc reference**, in `packages/README.md` (lines 95–97):

  ```markdown
  CI runs `lint` + `format:check` via
  [`../.github/workflows/lint.yml`](../.github/workflows/lint.yml), separate from
  the build/test workflow.
  ```

  Both the linked file and the "build/test workflow" it mentions do not exist.

- **The TS workspace** (`packages/`) is a Yarn Berry 4 + Turborepo monorepo.
  Its root `packages/package.json` defines these scripts (all delegate to
  `turbo run`):
  - `build`, `typecheck`, `test`, `lint`, `format`, `format:check`
  - `packages/package.json` also declares `"packageManager": "yarn@4.16.0"`.
  - `packages/.yarnrc.yml` sets `nodeLinker: node-modules` and
    `yarnPath: .yarn/releases/yarn-4.16.0.cjs` (the Yarn release binary is
    committed under `packages/.yarn/releases/`, which `.gitignore` keeps via
    `!packages/.yarn/releases`).
  - The single lockfile is `packages/yarn.lock` (committed).
  - `packages/turbo.json`: `typecheck` and `test` both `dependsOn: ["^build"]`,
    so a plain `yarn test` triggers dependency builds automatically. `build`
    outputs `dist/**`.
  - Each member's `package.json` implements the scripts, e.g.
    `packages/mxm4-haptic/package.json`: `"test": "node --test"`,
    `"typecheck": "tsc -p tsconfig.json --noEmit"`, `"lint": "eslint ."`,
    `"format:check": "prettier --check ."`, `"build": "tsdown"`.
  - Node engine constraint: every member declares `"engines": {"node": ">=20"}`.

- **The Rust crate** is `crates/mxm4-haptic/`. `Cargo.toml`: `edition = "2021"`,
  three `[[bin]]` targets plus a `[lib]`, release profile with `panic = "abort"`,
  `lto = true`. `Cargo.lock` is committed. The Linux HID backend feature is
  `linux-static-hidraw` (see `Cargo.toml` line 42), whose `hidapi` build links
  **libudev** — a Linux CI runner must have the `libudev` development headers
  and `pkg-config` installed or `cargo build` fails at link time.

- **Repo conventions** (from `AGENTS.md`): this is a chezmoi source-state repo;
  `.github/` begins with `.` so chezmoi never deploys it to `$HOME` (source
  paths starting with `.`, except `.chezmoi*`, are ignored) — it is safe
  repo-meta, exactly like the tracked `opencode.json`. Commits use Conventional
  Commits, lowercase subject, usually `chore(<area>)` (e.g. `chore(ci)`); see
  `git log --oneline -5`. Trunk-based on `main`; the remote is
  `https://github.com/hyperlapse122/dotfiles.git`.

- **Plain shell scripts** that `shellcheck` can lint directly (the `.sh.tmpl`
  files are Go templates and CANNOT be fed to shellcheck as-is — leave them out):
  - `.install-prerequisites.sh`
  - `dot_local/bin/executable_setup-luks-tpm2-unlock.sh`
  - `dot_agents/skills/glab/scripts/create-epic-note.sh`
  - `dot_agents/skills/glab/scripts/epic-notes.sh`

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| TS: install | `cd packages && corepack enable && yarn install --immutable` | exit 0, no lockfile change |
| TS: build | `cd packages && yarn build` | exit 0 |
| TS: typecheck | `cd packages && yarn typecheck` | exit 0 |
| TS: test | `cd packages && yarn test` | exit 0, all `node --test` pass |
| TS: lint | `cd packages && yarn lint` | exit 0 |
| TS: format | `cd packages && yarn format:check` | exit 0 |
| Rust: build | `cd crates/mxm4-haptic && cargo build --all-targets` | exit 0 |
| Rust: test | `cd crates/mxm4-haptic && cargo test` | exit 0, all pass |
| Rust: fmt | `cd crates/mxm4-haptic && cargo fmt --check` | exit 0 (only gate if it passes locally) |
| Shell lint | `shellcheck .install-prerequisites.sh dot_local/bin/executable_setup-luks-tpm2-unlock.sh dot_agents/skills/glab/scripts/create-epic-note.sh dot_agents/skills/glab/scripts/epic-notes.sh` | exit 0 (only gate if it passes locally) |
| YAML sanity | `yamllint .github/workflows/ci.yml` OR any local YAML parse | parses cleanly (optional) |

> **On a fresh clone / worktree**, `node_modules` and Rust build artifacts are
> absent — the install and first `cargo build` are expected to take time and
> download crates/packages. That is not a deviation.

## Suggested executor toolkit

- If a `ci-cd-monitoring` skill is available in your environment, consult it for
  GitHub Actions conventions.
- Reference: GitHub Actions docs for `actions/checkout`, `actions/setup-node`
  (with `corepack`), and a Rust toolchain action.

## Scope

**In scope** (the only files you should create or modify):
- `.github/workflows/ci.yml` (create)
- `packages/README.md` (edit ONLY the three-line CI reference, lines 95–97)

**Out of scope** (do NOT touch, even though they look related):
- Any source file under `crates/` or `packages/*/src/` — this plan adds
  verification, it does not change code. If a check fails because of a real code
  bug, that is a STOP condition (see below), not something to fix here.
- The `.sh.tmpl` provisioning scripts — do not try to shellcheck or "fix" them.
- `.chezmoiignore` — `.github/` is auto-ignored by chezmoi; do not add an entry.
- `dot_config/agent-of-empires/config.toml` — it shows as modified in the working
  tree; that is someone else's in-progress work. Leave it untouched and do not
  stage it.

## Git workflow

- Branch: `chore/add-ci-pipeline` (Git Flow prefix + human slug, per repo rules).
- Verify the branch name before the first commit: `git branch --show-current`.
- One commit; message style Conventional Commits, lowercase subject, e.g.
  `chore(ci): add github actions verification workflow`.
- Do NOT push or open a PR unless the operator instructed it. (This repo is
  trunk-based and normally pushes to `origin/main` immediately, but that is the
  operator's call, not yours.)

## Steps

### Step 1: Establish the local baseline — confirm every candidate check passes BEFORE writing the workflow

You must not ship a workflow whose first run is red. Run each command from the
"Commands you will need" table locally, from the repo root, and record the
result of each:

1. `cd packages && corepack enable && yarn install --immutable`
2. `yarn build` then `yarn typecheck` then `yarn test` then `yarn lint` then `yarn format:check` (still in `packages/`)
3. `cd ../crates/mxm4-haptic && cargo build --all-targets && cargo test`
4. `cargo fmt --check`
5. Back at repo root: the `shellcheck` command from the table.

Classify each as PASS or FAIL. The **required** jobs are the TS workspace checks
and the Rust build+test — these are known to pass (the suites exist and are
maintained). `cargo fmt --check` and `shellcheck` are **conditional**: include
them in the workflow ONLY if they pass locally now. If either fails locally, do
NOT fix the underlying files (out of scope) — omit that job and record it in the
plan's Maintenance notes as a follow-up.

**Verify**: you have a written PASS/FAIL for all five groups. If any *required*
group (TS checks, Rust build/test) FAILS, that is a STOP condition.

### Step 2: Create `.github/workflows/ci.yml`

Create the workflow with one job per independent check group. Target the
`ubuntu-latest` runner. Trigger on `push` and `pull_request`. Produce this
shape (fill the Node version to `20`, and include the `cargo-fmt` / `shellcheck`
steps ONLY if Step 1 marked them PASS):

```yaml
name: CI

on:
  push:
  pull_request:

jobs:
  ts-workspace:
    name: TypeScript workspace (packages/)
    runs-on: ubuntu-latest
    defaults:
      run:
        working-directory: packages
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: "20"
      - run: corepack enable
      - run: yarn install --immutable
      - run: yarn build
      - run: yarn typecheck
      - run: yarn test
      - run: yarn lint
      - run: yarn format:check

  rust-crate:
    name: Rust crate (crates/mxm4-haptic/)
    runs-on: ubuntu-latest
    defaults:
      run:
        working-directory: crates/mxm4-haptic
    steps:
      - uses: actions/checkout@v4
      - name: Install libudev (hidapi linux-static-hidraw backend)
        run: sudo apt-get update && sudo apt-get install -y libudev-dev pkg-config
      - uses: dtolnay/rust-toolchain@stable
      - run: cargo build --all-targets
      - run: cargo test
      # include ONLY if `cargo fmt --check` passed locally in Step 1:
      - run: cargo fmt --check

  shell-lint:            # include this whole job ONLY if shellcheck passed locally in Step 1
    name: Shellcheck (plain .sh scripts)
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: shellcheck
        run: |
          shellcheck \
            .install-prerequisites.sh \
            dot_local/bin/executable_setup-luks-tpm2-unlock.sh \
            dot_agents/skills/glab/scripts/create-epic-note.sh \
            dot_agents/skills/glab/scripts/epic-notes.sh
```

Notes for the executor:
- Pin action versions to a major tag (`@v4`, `@stable`) exactly as shown; do not
  invent SHAs.
- `dtolnay/rust-toolchain@stable` is a widely used community action; if your
  environment forbids it, substitute the equivalent official rustup step, but do
  not change what the job runs (`cargo build --all-targets`, `cargo test`).
- Do NOT add `cargo clippy` — it is not part of Step 1's baseline and may emit
  warnings that would make the first run red.

**Verify**: `git status` shows `.github/workflows/ci.yml` created. If you have a
YAML linter available, `yamllint .github/workflows/ci.yml` parses with no errors;
otherwise confirm the file is valid YAML by eye (indentation is 2 spaces, no
tabs).

### Step 3: Correct the stale CI reference in `packages/README.md`

Replace the lines 95–97 block quoted in "Current state" with text that points at
the workflow that now exists. Use exactly this replacement:

```markdown
CI runs the workspace `lint` + `format:check` (plus `build`, `typecheck`, and
`test`) via [`../.github/workflows/ci.yml`](../.github/workflows/ci.yml),
alongside the Rust crate build/test and shell linting.
```

Do not change any other part of `packages/README.md`.

**Verify**: `grep -n "workflows/ci.yml" packages/README.md` returns the new line,
and `grep -rn "workflows/lint.yml" packages/README.md` returns **nothing**.

### Step 4: Final local verification

Re-run the required check groups once more to be certain nothing regressed while
editing (they should be unchanged):

- `cd packages && yarn test` → all pass
- `cd crates/mxm4-haptic && cargo test` → all pass

**Verify**: both exit 0.

## Test plan

This plan adds verification infrastructure; it introduces no new application
tests. Its "test" is that every job it enables is green:

- The TS `test` job runs the existing `node --test` suites across all three
  members (drift-guard, send-command, waveforms, plugin, session).
- The Rust `test` job runs the existing `cargo test` unit suites.
- Confirm locally (Step 1 + Step 4) that all enabled jobs pass before committing.
- Verification: after the workflow is committed and (if the operator pushes) the
  run completes, every job is green. If any job is red, treat it as a STOP
  condition and report which job and why — do not disable or skip the job.

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `.github/workflows/ci.yml` exists and is valid YAML.
- [ ] `grep -rn "workflows/lint.yml" packages/` returns no matches.
- [ ] `grep -n "workflows/ci.yml" packages/README.md` returns the new reference.
- [ ] `cd packages && yarn install --immutable && yarn build && yarn typecheck && yarn test && yarn lint && yarn format:check` exits 0.
- [ ] `cd crates/mxm4-haptic && cargo build --all-targets && cargo test` exits 0.
- [ ] Every job written into `ci.yml` was confirmed to pass locally in Step 1/Step 4.
- [ ] No files outside the in-scope list are modified (`git status` — the
      pre-existing `dot_config/agent-of-empires/config.toml` modification is not
      yours and must remain unstaged).
- [ ] `plans/README.md` status row updated.

## STOP conditions

Stop and report back (do not improvise) if:

- A **required** check (TS build/typecheck/test/lint/format, or Rust build/test)
  FAILS locally. That means either the codebase has a real defect or the
  environment is missing a dependency you cannot install — report the exact
  command and output; do not "fix" source to make it pass.
- `cargo build` fails at link time even after installing `libudev-dev` +
  `pkg-config` (may indicate a different system-lib need on your runner).
- `packages/README.md` no longer contains the lines-95–97 block from "Current
  state" (the file drifted since this plan was written).
- Enabling the workflow would require changing any source file, lockfile, or
  config outside the in-scope list.

## Maintenance notes

- If `cargo fmt --check` or `shellcheck` were omitted because they failed
  locally, that failure is a genuine follow-up: a separate plan should fix the
  formatting / shell warnings and then add the corresponding job.
- The `.sh.tmpl` provisioning scripts are not linted here because shellcheck
  cannot parse Go-template syntax. A future improvement is to render them with
  `chezmoi execute-template` (needs 1Password auth) and shellcheck the output —
  deliberately deferred.
- A reviewer should confirm the workflow does not accidentally get deployed by
  chezmoi (it should not: `.github/` is auto-ignored). Sanity check with
  `chezmoi managed | grep github` → expect no output.
- When a new `packages/` member is added, the existing jobs cover it
  automatically (turbo runs across all members); no workflow change needed.
- If Node <20 is ever pinned in `mise`, the `engines` constraint will start
  failing installs — keep the CI Node version at ≥20.
