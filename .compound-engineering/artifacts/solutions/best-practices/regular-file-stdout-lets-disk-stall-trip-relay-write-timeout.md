---
title: "A test that sends the relay's output to a file lets a disk stall trip its write timeout"
date: "2026-10-19"
category: best-practices
module: pinentry-card wrapper and its checks
problem_type: best_practice
component: testing_framework
severity: medium
applies_when:
  - "The code under test gives up on a write that stays blocked for a fixed time, treating it as a client that stopped reading"
  - "A test sends that code's stdout straight to a regular file, as `>\"$out\"` does"
  - "A check fails once in CI with output cut short, the run took no longer than passing runs, and no timeout the test names was reached"
  - "Delay injection with strace must land on cat, cp, or another coreutils tool that copies with splice(2)"
symptoms:
  - "pinentry-card-darwin: FAIL: D11 slow-relay: 6 commands drew 6 replies (greeting included)"
  - "The failing run lasted about as long as passing runs; the 10-second EXIT_GRACE was nowhere near"
  - "Loaded serial runs and many parallel local runs never reproduce it"
root_cause: async_timing
resolution_type: code_fix
related_components:
  - tooling
tags:
  - flaky-ci
  - pinentry-card
  - disk-stall
  - strace
  - fault-injection
  - splice
  - pipes
---

# A test that sends the relay's output to a file lets a disk stall trip its write timeout

## Context

`scripts/pinentry-card` relays the delegate's replies to gpg-agent from a relay thread. On exit, `drain_relay` (`scripts/pinentry-card:248`) waits for the relay to pass on the replies still owed. Before PR #244 it gave up on any single write that had been in progress for `DIALOG_GRACE` (2 seconds, `scripts/pinentry-card:35`), on the assumption that a write blocked that long means the agent stopped reading. Shutdown then takes `output_lock` (`scripts/pinentry-card:338`; the darwin front stage at `scripts/pinentry-card-darwin:172`) and calls `os._exit`, which discards any reply the relay has not read yet.

The tests sent that stdout straight to a regular file in the Nix sandbox (`>"$out"`). A write to a file can block on the disk. In the scheduled dependency-update run 39158468718, whose pre-push `nix flake check` failed and which opened PR #244 to reconcile it, darwin test D11 lost its last reply: `6 commands drew 6 replies (greeting included): OK Pleased to meet you|OK|OK|OK|OK|OK|`. The runner stalled on I/O for about 2.8 seconds. The relay's write to the output file blocked through the stall, `drain_relay` read it as an agent that stopped reading, and `os._exit` dropped the reply still in the pipe.

How the cause was found, and what misled:

1. **The obvious suspect was the 10-second `EXIT_GRACE`.** D11 slows the relay by 0.5 seconds per line on purpose, so a loaded runner seemed able to push it past the bound. The log timestamps ruled that out. The failing D11 took about 4.4 seconds from D10's `ok` to D11's `FAIL`, close to the 3.8 to 3.9 seconds of passing runs. Whatever dropped the reply happened at the normal finishing time.
2. **Load did not reproduce it.** Twelve serial runs beside 48 busy loops, then 64 copies of the suite in parallel, all passed. CPU contention cannot block a write; a disk stall can.
3. **The CI log showed the stall.** Between 19:28:57.09 and 19:28:59.86 the GitHub log has no line from any builder or from nix itself. Nix's own `copying path` lines stopped too, so the whole runner was stalled on I/O, not one test. D11 was running in that window. An earlier 2.1-second gap of the same kind made D7 through D10 print in one batch, so log timestamps bound when a line was printed, not when the test step ran.

## Guidance

A write that is still in progress after a fixed time is not proof that the client stopped reading. The relay may have gone unscheduled inside the write, or the disk under a file may have stalled. A client that stopped reading leaves its pipe full, so ask the stream before giving up. `drain_relay` now counts a write as stuck only when stdout has no room (`scripts/pinentry-card:264`), through `has_room` (`scripts/pinentry-card:239`):

```python
def has_room(stream):
    try:
        return bool(select.select([], [stream], [], 0)[1])
    except (OSError, ValueError):
        return False

if writing_since is not None and now - writing_since >= DIALOG_GRACE and not has_room(client_out):
    return
```

A slow write then waits within the same `EXIT_GRACE` or `DIALOG_GRACE` bound as any other drain, so the exit stays bounded. Test 31, whose client stops reading and fills the pipe, still fails when the room check is forced to report room, so the guard against a stopped client keeps its coverage. Tests 36 and D12 stall the relay for 2.5 seconds inside one write and fail on the old guard.

Tests also give the code under test the kind of stdout it has in production, a pipe, through a one-line `pipe_into` helper (`cat >"$1"`):

```bash
# tests/pinentry-card-darwin.sh D11
printf '%s\n' "$input" | "$timeout_bin" 20 "$env_bin" -u DISPLAY -u WAYLAND_DISPLAY \
  PATH="$scratch/bin:/usr/bin:/bin" "$python3_bin" "$scratch/filter-slow-relay" 2>"$scratch/err11" |
  pipe_into "$scratch/out11" ||
  fail "D11 slow-relay: the filter failed: $(<"$scratch/err11")"
```

A disk stall then blocks `cat`, not the relay. A few dozen bytes of replies always fit in a pipe, whatever its capacity on the host. `set -euo pipefail` keeps the exit status of `timeout` or Python visible through the pipeline, and stderr still goes to its own file.

Apply it in the helpers behind the reply-counting assertions: `run_filter` (`tests/pinentry-card-darwin.sh:160`) and `run_wrapper` (`tests/pinentry-card.sh:249`). The signal tests that start the code in the background (`start_wrapper` for tests 29 and 34, and D10) still write to a file; they assert the exit status and how fast the process exits, never the replies, so a stall that cuts the drain short cannot fail them. Keep one exception: test 28 passes a slow FIFO as `run_wrapper`'s output because that FIFO plays the client that stopped reading. So `run_wrapper` writes a FIFO directly and pipes everything else (`if [[ -p $out ]]; then`, `tests/pinentry-card.sh:244`).

Reproduce a one-off stall by delaying the exact write with strace, and filter by path so no other write slows down:

```bash
# Red on the old wiring: the 6th write to out11 blocks 2.5 s, past DIALOG_GRACE
strace -f -qq -o /dev/null -P "$scratch/out11" \
  --inject=write:delay_enter=2500000:when=6 \
  "$python3_bin" "$scratch/filter-slow-relay" >"$scratch/out11"
```

That reproduced the CI output exactly, and a 1.5-second delay passed, which ties the failure to the 2-second bound. To show the fix holds, move the same stall to `cat`, but inject on `splice`. Coreutils `cat` copies a pipe to a file with `splice(2)` and makes no `write(2)` call, so `--inject=write` on `cat` never fires and the suite passes for the wrong reason. Write strace's log to a file and check that it marks the call `(DELAYED)` before trusting a green run:

```bash
... 2>"$scratch/err11" | strace -qq -o "$TMPDIR/cat.log" -P "$scratch/out11" \
  --inject=splice:delay_enter=2500000:when=6 cat >"$scratch/out11"
grep -c DELAYED "$TMPDIR/cat.log"   # must be 1
```

Run harnesses for `tests/pinentry-card.sh` inside a Nix `runCommand`. On the development host, tests 30 and 31 hang outside the sandbox, likely because of the per-user pipe quota the related learning below describes, so a direct run never reaches test 35.

## Why This Matters

A write timeout alone cannot tell a client that stopped reading from a relay that went unscheduled or a disk that stopped writing; only the stream's free room can. A test that sends output to a file hands every disk stall on a busy builder to such a timeout. The resulting failure looks like the scheduling flake the slow-relay tests already guard against, so the obvious diagnosis is to raise a time budget. That does not help: the dropped reply came from the 2-second write bound, not the 10-second drain budget. A delay injected on the wrong syscall also turns a fix check into a pass that proves nothing.

## When to Apply

- A test drives code that abandons a write after a fixed time, or treats a blocked write as a dead peer.
- A check fails once with output cut short and the run took no longer than usual.
- A CI log shows a gap in which no job printed anything during the failing test.
- A fault-injection check targets a copy tool such as `cat` or `cp`: confirm the syscall it uses with an strace log before injecting on it.

## Examples

Before, in `run_wrapper` and `run_filter`:

```bash
printf '%s\n' "$input" | "$timeout_bin" 10 "$env_bin" "$@" PATH="$scratch/bin:/usr/bin:/bin" \
  "$python3_bin" "$functional" >"$out" 2>"$err" || rc=$?
```

After, as in `run_wrapper`, which keeps a FIFO output direct for test 28:

```bash
if [[ -p $out ]]; then
  printf '%s\n' "$input" | "$timeout_bin" 10 "$env_bin" "$@" PATH="$scratch/bin:/usr/bin:/bin" \
    "$python3_bin" "$functional" >"$out" 2>"$err" || rc=$?
else
  printf '%s\n' "$input" | "$timeout_bin" 10 "$env_bin" "$@" PATH="$scratch/bin:/usr/bin:/bin" \
    "$python3_bin" "$functional" 2>"$err" | pipe_into "$out" || rc=$?
fi
```

After the change, D11 and test 35 still fail on the unfixed relay. With `drain_relay` replaced by `relay.join(timeout=2)`, D11 drew 4 replies for 6 commands and test 35 saw 3 of 7 `OK` replies.

Related: [a timing regression test built on pipe capacity can pass on the unfixed relay](pipe-capacity-timing-test-passes-on-the-unfixed-relay.md), which added the slow-relay tests, and [mutation testing for check assertions](mutation-testing-reveals-decorative-nix-check-assertions.md).
