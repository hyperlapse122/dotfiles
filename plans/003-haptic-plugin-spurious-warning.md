# Plan 003: Stop the haptic plugin from logging a false "failed to resolve session" warning on every root completion

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**:
> `git diff --stat 7a12e58..HEAD -- packages/opencode-mxm4-haptic/`
> If either file below changed since this plan was written, compare the "Current
> state" excerpts against the live code before proceeding; on a mismatch, treat
> it as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: bug
- **Planned at**: commit `7a12e58`, 2026-07-01

## Why this matters

The OpenCode haptic plugin decides whether a finished session is a top-level
("root") session or a sub-agent ("child") session, and only buzzes the mouse on
root completion. It resolves this with `client.session.get(...)` and a
`ts-pattern` `match`. The problem: a **successfully resolved root session** (one
with no `parentID`) falls through to the `.otherwise` branch, which is written
as the *error* branch — it logs a `warn`: "Failed to resolve session … assuming
it's a root session". So every normal top-level completion emits a misleading
warning claiming a failure that did not happen (with `extra.error` being
`undefined`). The behavior is correct (it still buzzes), but the log is wrong and
noisy: anyone reading the plugin's logs sees a "Failed to resolve" warning on
every successful run and reasonably concludes something is broken. The fix adds
an explicit "resolved, but no parentID → root, silently" branch so the warning
only fires on a genuine resolution failure.

## Current state

- **File**: `packages/opencode-mxm4-haptic/src/index.ts`. Relevant imports
  (line 3): `import { match, P } from "ts-pattern";` — note `P` is already
  imported, so `P.nonNullable` needs no new import.

- **The function, lines 38–56**:

  ```ts
  async function isChildSession(client: Client, sessionID: string): Promise<boolean> {
    try {
      return match(await client.session.get({ path: { id: sessionID } }))
        .with({ data: { parentID: P.string } }, () => true)
        .otherwise(async ({ error }) => {
          await client.app.log({
            body: {
              service: serviceName,
              level: "warn",
              message: `Failed to resolve session ${sessionID} to check if it's a child session — assuming it's a root session and buzzing accordingly.`,
              extra: { error },
            },
          });
          return false;
        });
    } catch {
      return false;
    }
  }
  ```

  `client.session.get` returns a result envelope shaped like
  `{ data?: Session } | { error?: … }`. A child session is
  `{ data: { parentID: "…" } }` (first branch → `true`). A **root** session is
  `{ data: { …, parentID: undefined } }` — it does **not** match the first
  branch, so it hits `.otherwise`, which logs the false warning. A real failure
  is `{ error: … }` (no `data`) — it *should* log.

- **Existing tests** (`packages/opencode-mxm4-haptic/test/plugin.test.ts`)
  already pin the surrounding behavior and must keep passing:
  - line 154 `"session.idle on a root session with no children buzzes COMPLETED"`
    (`get: async () => ({ data: {} })`) — asserts a `COMPLETED` pulse; does **not**
    currently assert on logs.
  - line 220 `"session.get returning an { error } envelope still buzzes and logs a
    warning"` (`get: async () => ({ error: { message: "boom" } })`) — asserts
    `logs.length === 1`, `logs[0].body.level === "warn"`. This must stay true:
    the error path must still log.
  - The test file's helpers you will reuse: `fakeClient(...)`, `plugin(client)`,
    `idleEvent(id)`, `tick()`, `startHapticServer()`.

- **Convention**: this package uses `ts-pattern` for control flow (see the
  `event` hook's `match(event).with(...).otherwise(...)`), exhaustive and typed.
  Match the existing style — add a `.with(...)` branch, do not rewrite the
  function into `if`/`else`.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Install (once) | `cd packages && corepack enable && yarn install --immutable` | exit 0 |
| Typecheck | `cd packages && yarn workspace @h82/opencode-mxm4-haptic typecheck` | exit 0, no errors |
| Test | `cd packages && yarn workspace @h82/opencode-mxm4-haptic test` | all pass, incl. the new test |
| Lint | `cd packages && yarn workspace @h82/opencode-mxm4-haptic lint` | exit 0 |
| Format check | `cd packages && yarn workspace @h82/opencode-mxm4-haptic format:check` | exit 0 |

> Fresh clone/worktree: run the install first; `typecheck`/`test` `dependsOn`
> `^build` via turbo, so they build the bundled `@h82/mxm4-haptic` dep first.
> The tests run under `node --test` on the repo's Node (≥ a version with
> TypeScript type-stripping); if `node --test` cannot load `.ts` files in your
> environment, that is a STOP condition — do not convert the tests to `.js`.

## Scope

**In scope** (the only files you should modify):
- `packages/opencode-mxm4-haptic/src/index.ts`
- `packages/opencode-mxm4-haptic/test/plugin.test.ts` (add one test)

**Out of scope** (do NOT touch):
- `allChildrenIdle`, `pulse`, the `event`/`tool.execute.before` hooks — unrelated.
- The `@h82/mxm4-haptic` client package — this is a logging fix in the plugin only.
- The warning message wording itself — keep it identical; only change *when* it fires.

## Git workflow

- Branch: `bugfix/haptic-plugin-root-session-warning`.
- Verify the branch name before the first commit: `git branch --show-current`.
- One commit; Conventional Commits, e.g.
  `fix(opencode-mxm4-haptic): stop false warning on resolved root sessions`.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Add a "resolved root session" branch before `.otherwise`

In `packages/opencode-mxm4-haptic/src/index.ts`, insert one `.with(...)` line so
a resolved session whose `data` is present (but has no `parentID`) returns
`false` silently. Change:

```ts
      .with({ data: { parentID: P.string } }, () => true)
      .otherwise(async ({ error }) => {
```

to:

```ts
      .with({ data: { parentID: P.string } }, () => true)
      // Resolved successfully but no parentID → a genuine root session. Return
      // false WITHOUT logging; the `.otherwise` below is only for a real
      // resolution failure (an `{ error }` envelope with no `data`).
      .with({ data: P.nonNullable }, () => false)
      .otherwise(async ({ error }) => {
```

Leave the `.otherwise` body (the `warn` log + `return false`) exactly as it is —
it now only runs when `data` is absent, i.e. a true failure.

Why this works: `ts-pattern` evaluates `.with` branches top-to-bottom, first
match wins. A child (`data.parentID` is a string) matches branch 1 → `true`. A
root (`data` present, no `parentID`) skips branch 1, matches the new branch 2 →
`false`, no log. A failure (`{ error }`, `data` undefined) matches neither →
`.otherwise` → logs `warn`.

**Verify**: `cd packages && yarn workspace @h82/opencode-mxm4-haptic typecheck` → exit 0.

### Step 2: Add a regression test that a resolved root session logs nothing

In `packages/opencode-mxm4-haptic/test/plugin.test.ts`, add this test
immediately after the existing `"session.idle on a root session with no children
buzzes COMPLETED"` test (it ends around line 165, right before the
`"session.idle on a child session (parentID) stays silent"` test):

```ts
  test("session.idle on a resolved root session logs NO warning (resolved root is not a failure)", async () => {
    const server = await startHapticServer();
    const { client, logs } = fakeClient({ get: async () => ({ data: {} }) });
    try {
      const hooks = await plugin(client);
      await hooks.event!({ event: idleEvent("root-1") } as never);
      await tick();
      assert.deepEqual(server.received, ["COMPLETED\n"]);
      assert.equal(logs.length, 0);
    } finally {
      await server.cleanup();
    }
  });
```

This asserts `logs.length === 0` on the resolved-root path. Before Step 1 this
test FAILS (the spurious warning makes `logs.length === 1`); after Step 1 it
passes. The existing line-220 test (`{ error }` envelope → `logs.length === 1`)
must still pass, proving the warning still fires on real failures.

**Verify**: `cd packages && yarn workspace @h82/opencode-mxm4-haptic test` → all
tests pass, including the new one AND the existing `{ error }`-envelope test.

### Step 3: Lint + format

```sh
cd packages
yarn workspace @h82/opencode-mxm4-haptic lint
yarn workspace @h82/opencode-mxm4-haptic format:check
```

**Verify**: both exit 0. If `format:check` fails only on your new lines, run
`yarn workspace @h82/opencode-mxm4-haptic format` to auto-format, then re-run
`format:check`.

## Test plan

- **New test** in `packages/opencode-mxm4-haptic/test/plugin.test.ts`: "resolved
  root session logs NO warning" — asserts the pulse still fires (`COMPLETED\n`)
  AND `logs.length === 0`. This is the direct regression guard for this fix.
- **Existing tests that must still pass** (do not modify them): the root-session
  buzz test (line 154), the child-session-silent test, and especially the
  `{ error }`-envelope test (line 220) which proves the warning still fires on a
  genuine failure.
- Model the new test on the existing tests in the same file (same `fakeClient` /
  `startHapticServer` / `tick` scaffolding).
- Verification: `yarn workspace @h82/opencode-mxm4-haptic test` → all pass,
  including 1 new test.

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `cd packages && yarn workspace @h82/opencode-mxm4-haptic typecheck` exits 0.
- [ ] `cd packages && yarn workspace @h82/opencode-mxm4-haptic test` exits 0; the new "logs NO warning" test exists and passes; the existing `{ error }`-envelope test still passes.
- [ ] `cd packages && yarn workspace @h82/opencode-mxm4-haptic lint` exits 0.
- [ ] `cd packages && yarn workspace @h82/opencode-mxm4-haptic format:check` exits 0.
- [ ] `grep -n "P.nonNullable" packages/opencode-mxm4-haptic/src/index.ts` shows the new branch.
- [ ] Only the two in-scope files are modified (`git status`; the pre-existing
      `dot_config/agent-of-empires/config.toml` change is not yours — leave it unstaged).
- [ ] `plans/README.md` status row updated.

## STOP conditions

Stop and report back (do not improvise) if:

- The `isChildSession` body in the live file does not match the "Current state"
  excerpt (drift since this plan was written).
- After Step 1, the existing line-220 `{ error }`-envelope test FAILS — that
  means the new `{ data: P.nonNullable }` branch is also swallowing the error
  case; report it rather than deleting or weakening that test.
- `typecheck` fails on the new `.with({ data: P.nonNullable }, () => false)`
  line (the SDK's result type differs from what this plan assumed) — report the
  type error; do not cast with `as any` or `@ts-ignore`.
- `node --test` cannot load the `.ts` test files in your environment.

## Maintenance notes

- The logging semantics now distinguish three cases: child (branch 1, silent),
  resolved root (branch 2, silent), resolution failure (`.otherwise`, warns).
  If the OpenCode SDK ever changes `session.get`'s envelope shape (e.g. returns
  `null` instead of `{ error }` on failure), re-check that the failure case still
  reaches `.otherwise`.
- A reviewer should confirm the `.otherwise` body was left byte-for-byte
  unchanged and that the only new runtime behavior is "no log on resolved root".
