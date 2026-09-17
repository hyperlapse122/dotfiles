---
title: Self-Written GnuPG Stubs Made Every Card Gate Pass Against Formats GnuPG Never Emits
date: 2026-09-18
category: test-failures
module: gnupg
problem_type: test_failure
component: testing_framework
symptoms:
  - "every new card gate passes while the same code path fails on the first real YubiKey"
  - "a parser reads scdaemon status, card serials, and key stubs in shapes no GnuPG build produces"
  - "a review that checks fixtures against GnuPG source finds four wrong formats the green suite certified"
root_cause: test_isolation
resolution_type: code_fix
severity: high
tags: [gnupg, scdaemon, smartcard, test-fixtures, stubs, assuan]
---

# Self-Written GnuPG Stubs Made Every Card Gate Pass Against Formats GnuPG Never Emits

## Problem

The YubiKey-only key custody work added four CI gates covering the key presence check and the card-PIN pinentry wrapper. All of them passed. Four separate parsers were nonetheless wrong, because each gate's stub `gpg`, `gpg-connect-agent`, and key-file fixture emitted the shape the test author assumed rather than the shape GnuPG produces. On a real card the check would have failed at its first step and spent PIN retries doing it.

## Symptoms

- Green gates for code that could not work on any real card.
- Four independent format assumptions, each wrong in the same direction: simpler and more regular than reality.
- The errors were invisible to the implementer, the gates, and the local reviewers; only a lens that read GnuPG's own source caught them.

## What Didn't Work

- **Testing the parser against its own stub.** The stub and the parser were written from one mental model, so they agreed with each other and with nothing else. A passing assertion proved only internal consistency.
- **Trusting a plausible-looking wire format.** `S CHV-STATUS 1 127 127 127 3 3 3` reads like a status line and is easy to split on spaces. It is not what scdaemon sends.
- **Assuming a field means what its name suggests.** "Serial number" in a `gpg -K --with-colons` record is the token's AID, not the decimal serial printed on the key.

## Solution

Each fixture was replaced with the shape quoted from GnuPG source, and the parsers were corrected to match:

| What the code read | What GnuPG actually emits |
|---|---|
| `S CHV-STATUS 1 127 127 127 3 3 3`, split on spaces | one status-encoded token: `S CHV-STATUS +1+127+127+127+3+3+3` — `send_status_info()` percent/plus-encodes every space, so the seven counters arrive as field 3 and must be decoded before splitting |
| field 15 of `gpg -K --with-colons` holds a decimal serial such as `14963605` | it holds the token AID, `D2760001240100000006149636050000`; the decimal serial appears nowhere in that record |
| a card stub file contains `shadowed-key` | GnuPG 2.4's own `agent/protect.c` writes `(20:shadowed-private-key`; the substring `shadowed-key` never occurs, so a grep for it rejects every genuine stub |
| `/let pin` needs `$` escaped | `gpg-connect-agent` performs no substitution unless the session sends `/subst`, so `/let` stores its value literally and the escape corrupts the PIN |

The corrected stubs now store and emit those exact strings, so the gates fail when a parser drifts back.

## Why This Works

A stub is an assertion about someone else's program. Written from memory it encodes the author's model of that program, and the test then measures the code against that model instead of against the program. The failure is silent by construction: the more faithfully the code matches the stub, the greener the suite, and the closer the first real run is to a hard failure. Deriving each fixture from the emitting source — the `printf` that formats the line, the function that writes the file, the parser that consumes the command — replaces the model with the thing itself.

The cost asymmetry matters here. Two of these parsers sit in front of a PIN retry counter that locks a YubiKey after three wrong attempts, so a format error does not merely fail a step: it spends a scarce, physical resource on the way down.

## Prevention

- **Quote the source next to the fixture.** Every fixture in these gates now carries the upstream GnuPG file and function it was derived from (in the GnuPG 2.4 tree, not this repository: `scd/app-openpgp.c`, `agent/protect.c`), so the next reader can re-check it without re-deriving it.
- **Treat a green suite over self-written stubs as unproven, not proven.** When the code under test parses another program's output, the gate's real question is whether the fixture is right; ask it explicitly in review.
- **Prefer a captured transcript to a hand-written one.** A recorded real exchange cannot encode an assumption.
- **When the parsed program is installed, check the format directly.** A read-only probe (`gpg-connect-agent`, `gpg -K --with-colons` in a scratch `GNUPGHOME`) settles the question in seconds and needs no card.
- **Give a cross-model or source-reading review lens the fixtures, not just the code.** Every one of these four was found by reading GnuPG's source against the fixture; none was found by reading the diff.

## Related Issues

- `docs/plans/2026-09-17-2211-refactor-yubikey-only-gpg-private-key-plan.md` — the plan whose KTD1, KTD2, and KTD3 these formats implement; its text carried two of the same wrong assumptions until this review corrected them.
- `docs/solutions/integration-issues/fedora-mok-import-sudo-prompt-inside-expect-pty.md` — the other case in this repository where an interaction with an external program behaved differently than its scripted model.
