# Plan 005: Add unit tests for the notify bridge's D-Bus message parsers

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**:
> `git diff --stat 7a12e58..HEAD -- crates/mxm4-haptic/src/bin/mxm4-haptic-notify.rs`
> If the file changed since this plan was written, compare the "Current state"
> excerpts against the live code before proceeding; on a mismatch, treat it as a
> STOP condition.

## Status

- **Priority**: P3
- **Effort**: M
- **Risk**: LOW
- **Depends on**: none (but benefits from plan 001 — CI will then run these tests)
- **Category**: tests
- **Planned at**: commit `7a12e58`, 2026-07-01

## Why this matters

`crates/mxm4-haptic/src/bin/mxm4-haptic-notify.rs` bridges desktop notifications
to haptic pulses by spawning `dbus-monitor` and **parsing its stdout by hand**.
Three pure functions do that parsing — `first_string` (app name), `first_uint32`
(replaces_id), and `urgency_byte` (urgency level) — and they drive real behavior:
a wrong `urgency_byte` sends the wrong waveform (or none), a wrong
`first_uint32` breaks the "skip notification updates" logic. Unlike the crate's
library code (`lib.rs` has ~30 tests) and the daemon's `drain_latest`
(`mxm4-hapticd.rs` has tests), these text parsers have **zero** coverage, even
though they are the most format-fragile code in the crate (they depend on
`dbus-monitor`'s exact output shape). They are pure `&str -> Option<…>`
functions — trivial to test and exactly the kind of parser that should be
locked against silent regressions. This plan adds a `#[cfg(test)]` module for
them; it changes no production behavior.

## Current state

- **File**: `crates/mxm4-haptic/src/bin/mxm4-haptic-notify.rs`. The three
  parsers are `#[cfg(target_os = "linux")]`-gated (the whole bridge is
  Linux-only; off-Linux the binary is a stub `main`). Their exact bodies
  (lines 44–84):

  ```rust
  /// First `string "..."` arg in a dbus-monitor message block = app_name.
  #[cfg(target_os = "linux")]
  fn first_string(text: &str) -> Option<String> {
      for line in text.lines() {
          if let Some(rest) = line.trim_start().strip_prefix("string \"") {
              let end = rest.rfind('"')?;
              return Some(rest[..end].to_string());
          }
      }
      None
  }

  /// First `uint32 N` arg = replaces_id.
  #[cfg(target_os = "linux")]
  fn first_uint32(text: &str) -> Option<u32> {
      for line in text.lines() {
          if let Some(rest) = line.trim_start().strip_prefix("uint32 ") {
              return rest.trim().parse().ok();
          }
      }
      None
  }

  /// `urgency` hint is a byte in the hints dict: the `byte N` line that
  /// follows the `string "urgency"` entry. Absent => spec default normal (1).
  #[cfg(target_os = "linux")]
  fn urgency_byte(text: &str) -> Option<u8> {
      let mut after_urgency = false;
      for line in text.lines() {
          if line.contains("\"urgency\"") {
              after_urgency = true;
              continue;
          }
          if after_urgency {
              if let Some(i) = line.find("byte ") {
                  return line[i + 5..].trim().parse().ok();
              }
          }
      }
      None
  }
  ```

- **Exemplar to model the tests on**: the sibling binary
  `crates/mxm4-haptic/src/bin/mxm4-hapticd.rs` already has a `#[cfg(test)] mod
  tests { use super::*; … }` block at the end (lines 359–381) — proving that a
  `cargo test` picks up `#[cfg(test)]` modules inside **binary** targets in this
  crate. `lib.rs` (lines 415–742) is the fuller example of the crate's test
  style: `#[test]` fns with `assert_eq!`, grouped by the function under test.

- **The functions are private** (`fn`, not `pub`). A `#[cfg(test)] mod tests`
  in the same file reaches them via `use super::*;`.

- **Gating**: because the parsers are `#[cfg(target_os = "linux")]`, the test
  module must also be Linux-gated (`#[cfg(all(test, target_os = "linux"))]`),
  or it will fail to compile on macOS/Windows where the functions don't exist.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Targeted test (no libudev needed) | `cd crates/mxm4-haptic && cargo test --bin mxm4-haptic-notify` | compiles + all new tests pass |
| Full crate test (needs libudev on Linux) | `cd crates/mxm4-haptic && cargo test` | all pass |
| Format | `cd crates/mxm4-haptic && cargo fmt --check` | exit 0 |

> Prefer `cargo test --bin mxm4-haptic-notify`: the notify binary does **not**
> link `hidapi`, so it builds without the `libudev` system dependency that the
> daemon binary needs. A full `cargo test` compiles the daemon too and therefore
> requires `libudev-dev` + `pkg-config` on Linux (see plan 001).

## Suggested executor toolkit

- If a Rust-focused skill/linter is available, use it to confirm the test module
  matches crate conventions (naming, `assert_eq!` style). Otherwise mirror
  `mxm4-hapticd.rs`'s `mod tests`.

## Scope

**In scope** (the only file you should modify):
- `crates/mxm4-haptic/src/bin/mxm4-haptic-notify.rs` (append a test module)

**Out of scope** (do NOT touch):
- The three parser functions themselves and any other production code in the
  file — this plan **only adds tests**. If a test reveals a genuine parser bug,
  that is a STOP condition (report it); do not "fix" the parser here.
- `lib.rs`, `mxm4-hapticd.rs`, `mxm4-haptic.rs` — out of scope.
- Any change to `Cargo.toml` (no new dependencies; tests use only `std`).

## Git workflow

- Branch: `test/notify-bridge-dbus-parsers`.
- Verify the branch name before the first commit: `git branch --show-current`.
- One commit; Conventional Commits, e.g.
  `test(mxm4-haptic): cover notify-bridge dbus parsers`.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Append the test module to `mxm4-haptic-notify.rs`

Add this module at the **end** of `crates/mxm4-haptic/src/bin/mxm4-haptic-notify.rs`
(after the final `}` of the Linux `main`, i.e. after line 172). The
`NOTIFY_BLOCK` constant is a representative `dbus-monitor` block for an
`org.freedesktop.Notifications` `Notify` method call (arg order: app_name,
replaces_id, app_icon, summary, body, actions[], hints{urgency}, expire_timeout):

```rust
#[cfg(all(test, target_os = "linux"))]
mod tests {
    use super::*;

    // A representative dbus-monitor message block for a Notify method call.
    const NOTIFY_BLOCK: &str = r#"method call time=1700000000.0 sender=:1.100 -> destination=org.freedesktop.Notifications serial=42 path=/org/freedesktop/Notifications; interface=org.freedesktop.Notifications; member=Notify
   string "Firefox"
   uint32 0
   string "firefox"
   string "Download complete"
   string "report.pdf finished downloading"
   array [
   ]
   array [
      dict entry(
         string "urgency"
         variant             byte 2
      )
   ]
   int32 -1"#;

    #[test]
    fn first_string_returns_app_name() {
        assert_eq!(first_string(NOTIFY_BLOCK).as_deref(), Some("Firefox"));
    }

    #[test]
    fn first_string_none_when_no_string_line() {
        assert_eq!(first_string("uint32 5\nint32 -1"), None);
    }

    #[test]
    fn first_string_keeps_embedded_quotes_via_last_quote() {
        // rfind('"') is greedy: an app_name containing quotes is returned whole.
        assert_eq!(
            first_string("   string \"a \"quoted\" name\"").as_deref(),
            Some("a \"quoted\" name")
        );
    }

    #[test]
    fn first_uint32_returns_replaces_id() {
        assert_eq!(first_uint32(NOTIFY_BLOCK), Some(0));
    }

    #[test]
    fn first_uint32_first_match_wins() {
        assert_eq!(first_uint32("uint32 7\nuint32 9"), Some(7));
    }

    #[test]
    fn first_uint32_none_when_absent() {
        assert_eq!(first_uint32("string \"x\"\nint32 -1"), None);
    }

    #[test]
    fn urgency_byte_reads_value_after_urgency_entry() {
        assert_eq!(urgency_byte(NOTIFY_BLOCK), Some(2));
    }

    #[test]
    fn urgency_byte_normal_urgency() {
        let block = "dict entry(\n   string \"urgency\"\n   variant             byte 1\n)";
        assert_eq!(urgency_byte(block), Some(1));
    }

    #[test]
    fn urgency_byte_none_when_no_urgency_hint() {
        // No urgency entry at all → None (the caller defaults to normal=1).
        assert_eq!(urgency_byte("string \"category\"\nvariant byte 3"), None);
    }

    #[test]
    fn urgency_byte_none_when_urgency_has_no_following_byte() {
        assert_eq!(urgency_byte("string \"urgency\""), None);
    }
}
```

**Verify**: `cd crates/mxm4-haptic && cargo test --bin mxm4-haptic-notify` →
compiles and all 10 new tests pass.

### Step 2: Format check

```sh
cd crates/mxm4-haptic && cargo fmt --check
```

If it reports diffs only in your new module, run `cargo fmt` then re-check.

**Verify**: `cargo fmt --check` exits 0.

## Test plan

- **New tests** (10) in the appended `#[cfg(all(test, target_os = "linux"))] mod
  tests` block of `crates/mxm4-haptic/src/bin/mxm4-haptic-notify.rs`, covering:
  - `first_string`: happy path (app name), no-string-line → `None`, embedded
    quotes handled by the greedy `rfind`.
  - `first_uint32`: happy path (replaces_id), first-match-wins, absent → `None`.
  - `urgency_byte`: critical (2) and normal (1) after the urgency entry,
    no-urgency-hint → `None`, urgency entry with no following `byte` line → `None`.
- **Pattern**: modeled on `crates/mxm4-haptic/src/bin/mxm4-hapticd.rs`'s existing
  `mod tests` (`use super::*;`, `#[test]`, `assert_eq!`).
- Verification: `cargo test --bin mxm4-haptic-notify` → all pass, 10 new tests.

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `cd crates/mxm4-haptic && cargo test --bin mxm4-haptic-notify` exits 0 with 10 new tests passing.
- [ ] `cd crates/mxm4-haptic && cargo fmt --check` exits 0.
- [ ] `grep -c "#\[test\]" crates/mxm4-haptic/src/bin/mxm4-haptic-notify.rs` → `10`.
- [ ] Only `crates/mxm4-haptic/src/bin/mxm4-haptic-notify.rs` is modified
      (`git status`; the pre-existing `dot_config/agent-of-empires/config.toml`
      change is not yours — leave it unstaged).
- [ ] The three parser functions are byte-for-byte unchanged (only a test module
      was appended): `git diff crates/mxm4-haptic/src/bin/mxm4-haptic-notify.rs`
      shows additions only, all inside the new `mod tests`.
- [ ] `plans/README.md` status row updated.

## STOP conditions

Stop and report back (do not improvise) if:

- The parser bodies in the live file do not match the "Current state" excerpts
  (drift since this plan was written).
- Any new test **fails** — that means the parser's real behavior differs from
  the documented intent (a genuine bug). Report the failing case and the actual
  output; do NOT change the parser to make the test pass, and do NOT weaken the
  test.
- `cargo test --bin mxm4-haptic-notify` fails to compile for a reason other than
  a test typo you can fix (e.g. the functions aren't reachable via `use super::*`).

## Maintenance notes

- These tests pin the parsers to `dbus-monitor`'s current output shape. If the
  `dbus-monitor` output format ever changes (or the bridge is reworked to use a
  proper D-Bus library instead of scraping text), update `NOTIFY_BLOCK` and the
  expectations together.
- The thin client binary `mxm4-haptic.rs` (`usage_spec()` / arg handling) remains
  untested; it is trivial and low-risk, deliberately left out of this plan. If it
  grows logic, add a sibling `mod tests` the same way.
- Once plan 001 (CI) lands, these tests run automatically on every push — that is
  the point of adding them. A reviewer should confirm the tests assert real
  parsed values (not just "does not panic").
