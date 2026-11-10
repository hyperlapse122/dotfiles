---
title: "A timing regression test built on pipe capacity can pass on the unfixed relay"
date: "2026-10-08"
last_updated: "2026-10-19"
category: best-practices
module: pinentry-card wrapper and its checks
problem_type: best_practice
component: testing_framework
severity: medium
applies_when:
  - "A test must reproduce a thread or process that is slow to be scheduled, such as a relay thread on a loaded CI runner"
  - "The test makes the code under test slow by pushing data volume through a pipe or FIFO and a slow reader"
  - "The code under test holds a lock while it writes, and a shutdown path waits on that lock with its own timeout"
root_cause: async_timing
resolution_type: test_fix
related_components:
  - tooling
tags:
  - flaky-ci
  - pinentry-card
  - threads
  - pipes
  - fault-injection
  - mutation-testing
---

# A timing regression test built on pipe capacity can pass on the unfixed relay

## Context

`scripts/pinentry-card` is an Assuan proxy in front of the desktop pinentry (the "delegate"). A daemon relay thread copies the delegate's stdout to gpg-agent. When stdin closed, `shutdown()` reaped the delegate, then gave the relay a flat `relay.join(timeout=2)` and called `os._exit`. On a loaded GitHub runner (CI run 37764071407, `check-shards (light-1)`), test 15 piped seven commands and EOF in at once. The delegate answered all seven, but only one `OK` reached stdout. The relay had not been scheduled to pass the rest on within 2 seconds, and `os._exit` discarded what was still in the pipe.

The wrapper fix lets the relay drain while a reply is still owed (`drain_relay`, `scripts/pinentry-card:248`; the darwin front stage calls it at `scripts/pinentry-card-darwin:171`). The lesson worth keeping is how hard it was to write a regression test that tells the old code from the new.

What did not work, in order:

1. **Fault injection with `strace -f -e inject=write:delay_enter=...`.** It slowed every `write`, including the delegate's own replies. The relay kept pace with a delegate that was just as slow, so test 15 passed.
2. **Data volume through a slow reader.** The delegate wrote 200 KB of `D` lines before its `OK` into a FIFO read at 40 KB/s. This passed on the unfixed code. A relay blocked in a write to a full pipe holds `output_lock`, and after the 2-second join the old shutdown also waited up to 2 seconds in `output_lock.acquire(timeout=2)` (the same statement is now `scripts/pinentry-card:338`). If the relay takes the lock back between writes, the old code waits up to about 4 seconds, not 2.
3. **More volume and a slower reader** (130 KB at 20 KB/s, and `F_SETPIPE_SZ` to fix the FIFO at 64 KiB). This went red on the base in the Nix sandbox. The independent cross-model review then showed that the result depended on pipe capacity, which the test does not control:
   - On a host past its per-user pipe quota, new pipes come out at 8 KiB (per that review's probe). Backpressure then kept the delegate alive until almost everything had been relayed, so the leftover fit inside the old 2-second window and the test passed on the unfixed code.
   - Under the same quota, `F_SETPIPE_SZ` to 64 KiB raises `EPERM`. The reader died before reading, so the test failed on correct code.

The same quota is a likely reason why tests 30 and 31, which fill a pipe on purpose, hung when the suite ran outside the Nix sandbox on the development host.

## Guidance

Reproduce a scheduling delay with a delay, not with data volume. Render a test-only copy of the code under test with a sleep at the exact point where the real delay happens. Guard the edit so that a missed anchor fails the test rather than leaving a copy that is not slowed down.

```bash
# tests/pinentry-card.sh, test 35: the relay stalls 0.5 s per line, outside the lock
sed '/^        chunk = delegate_stdout.readline()$/a\        time.sleep(0.5)' \
  "$scratch/functional-gnome.py" >"$scratch/functional-slow-relay.py"
grep -qFx '        time.sleep(0.5)' "$scratch/functional-slow-relay.py" || fail '35 slow-relay: the test could not slow the relay down'
```

Darwin test D11 (`tests/pinentry-card-darwin.sh:349`) does the same to the front stage's `line = child_stdout.readline()`.

The sleep sits after the read and outside `output_lock`. That matches the CI failure: the replies are already in the pipe and nothing holds the lock, so the old shutdown's lock wait returns at once and only the 2-second join stands between the relay and `os._exit`. The test needs no pipe sizes, no slow reader, and no extra time budget. Eight lines take about 4 seconds, well inside `run_wrapper`'s 10-second bound and the 10-second `EXIT_GRACE`. It does need its stdout on a pipe rather than a file, or a disk stall trips the relay's 2-second write limit instead: see [a test that sends the relay's output to a file lets a disk stall trip its write timeout](regular-file-stdout-lets-disk-stall-trip-relay-write-timeout.md).

Then confirm the test fails on the old code before trusting it. In this session, test 35 saw 3 of 7 `OK` replies on the base scripts, and D11's output was empty. Both pass on the fix.

## Why This Matters

A pipe's capacity depends on the host: the default size, the per-user pipe quota, and whether `F_SETPIPE_SZ` is allowed. A test whose result depends on it can go red on correct code on one machine and green on the bug on another, and both look like flakes. A blocking write can also stretch a timeout through a lock, so the bound under test is not the one the code names. A sleep at the real point of delay keeps both effects out of the test.

## When to Apply

- Writing a regression test for a timeout that gives up on a slow thread or child process.
- When the only obvious way to make the code slow is to fill a pipe, socket buffer, or disk.
- When a test that fills a pipe passes in the Nix sandbox but hangs or fails when run directly on a workstation.

## Examples

The volume-based test that was dropped. It is capacity-dependent and passes on the unfixed code with 8 KiB pipes:

```bash
"$python3_bin" -c '
import fcntl, os, sys, time
fcntl.fcntl(0, fcntl.F_SETPIPE_SZ, 65536)   # EPERM under the user pipe quota
...
        time.sleep(0.2)
' "$scratch/out35" <"$slow_fifo" &
printf 'GETINFO pid\n' | ... FAKE_DELEGATE_DATA_LINES=130 ... >"$slow_fifo"
```

The replacement is the rendered copy above, run with the same input as test 15, and it asserts `[[ $ok_count -eq 7 ]]`.

Related: [mutation testing for check assertions](mutation-testing-reveals-decorative-nix-check-assertions.md) and [fixture state that cannot distinguish a bug from its fix](converged-fixture-state-defeats-nix-check-mutation-testing.md).
