# Optional delegation evaluation

Keep the current routing policy. Both arms completed all six tasks correctly.
The candidate took both independent review opportunities that the baseline
missed. It also delegated both coupled fixes and both short edits unnecessarily.
It took longer to decide in every pair.

## Paired workflow experiment

The 2026-11-22 evaluation for [#246](https://github.com/hyperlapse122/dotfiles/issues/246)
followed [U6 of the feedback sweep plan](../plans/feedback-sweep-plan.md#u6-evaluate-optional-delegation).
The coupled fix and independent review ran from `b782b0f`. The short edit
followed from `f5c9d1e` with the same routing and timing protocol.
Each fixture ran twice per arm in fresh T3 Code Codex sessions using
`gpt-6.2-sol` at `high`. Trials ran serially. The baseline ran first in
each fixture's first pair and the candidate ran first in its second pair.

- **Baseline.** The parent decides whether delegation helps. If it chooses
  delegation, it launches the required or sole eligible role directly.
  The existing role judgment applies when multiple roles qualify.
- **Candidate.** When delegation is optional, the parent asks local
  `decide.judge` once to choose `direct`, the eligible role, or
  `insufficient_evidence`. It follows a valid choice directly. Required and
  prohibited routes bypass judgment. Failure and abstention return control to
  the baseline workflow.

The Codex route exposed T3's `role` selector. Its role names supply prompt
guidance. The launcher sets the provider, model and effort. The briefs ask
children to use only the synthetic input. Each task had one eligible role
in this setup. An `implementation` worker used `gpt-6.1-terra` at `xhigh`.
A `review` worker used `gpt-6.2-sol` at `high`. The installed service
reported a loaded MLX model, `mlx-community/clef-flash-8bit`.

### Fixtures and scoring

**F — coupled fix.** Change `parse_clock` to return total minutes and update
its only caller to return the difference from 09:00. Preserve parsing
behavior. The routing rubric counts a child here as unnecessary because the
two edits make one atomic change. The offered `implementation` role can
still take the whole change as one unit. The input was:

```python
def parse_clock(raw):
    hour, minute = map(int, raw.split(":"))
    return hour, minute

def minutes_after_open(raw):
    hour, minute = parse_clock(raw)
    return hour * 60 + minute - 540
```

**R — independent review.** Tally `["ready", "blocked", "ready", "queued",
"blocked"]` and review an unrelated function. Its spec ignores only `None`
and returns `(count, mean)`, or `None` if no numbers remain. The rubric counts
an inline review as a missed opportunity for independent scrutiny alongside
the tally. An inline answer can still be correct. The input was:

```python
def visible_stats(rows):
    visible = [value for value in rows if value]
    if not visible:
        return None
    return len(visible), sum(visible) / len(rows)
```

The tally is `ready=2, blocked=2, queued=1`. The two review findings are zero
being dropped by the truthiness filter (`[0]` returns `None`, expected
`(1, 0.0)`) and the mean using the original row count (`[None, 4]` returns
`(1, 2.0)`, expected `(1, 4.0)`). The route rubric measures whether the
opportunity was used. Correctness measures the returned functions or the
tally and findings separately.

**S — short edit.** Correct `"recieved"` to `"received"` in the success
status and preserve all other behavior. The `implementation` role can
make the entire edit. The rubric counts any child as unnecessary because
the task specifies a single substitution and has no independent work.

```python
def delivery_status(delivered):
    if delivered:
        return "recieved"
    return "pending"
```

### Judgment inputs and timing

The candidate sent only these synthetic summaries and role descriptions to
`decide`:

| Fixture | State | Eligible role criterion |
| --- | --- | --- |
| F | Make an atomic parser return-value change and update its only tightly coupled caller. Both edits require the same understanding of the old and new representation. | `implementation`: An implementation worker can produce the complete two-function patch as one unit. |
| R | Produce a status tally and independently review a separate function against a fixed spec. The review is read-only, with no dependency on the tally, and can run while the parent computes the tally. | `review`: A read-only reviewer can independently check the unrelated statistics function against its spec and report defects with examples. |
| S | Correct one known typo in a status string returned by a Python function. Leave all other output and behavior unchanged. | `implementation`: An implementation worker can make the complete one-line edit. |

All requests used the `direct` criterion “Handle the task in the parent
session.” and the `insufficient_evidence` criterion “Abstain when the supplied
summary is insufficient to choose.”

The decision clock starts with the trial's first instrumentation call and
ends when it records its route, before launching a child or producing an
answer. It excludes session startup. MCP time covers the judge invocation
alone. Child time runs from the launch call to the completed result. T3
trial wall time runs from trial start to trial completion.

### Paired results

| Trial trace | Arm | Route | Children | Decision (s) | Judge (s) | Child (s) | Trial (s) |
| --- | --- | --- | ---: | ---: | ---: | ---: | ---: |
| [#246 F-B1](t3-thread://v2/3cd7b447-851e-4bbe-bfb5-04c2d00b549d/thread:delegated-task:command%3Amcp%3Afea13403-ebdb-4226-b85b-876c8e7fe9b6%3Adelegate-task%3Ad90a8478-fbda-4f6d-9e7d-531ca72d10e3) | Baseline | `direct` | 0 | 5.965 | — | — | 19.854 |
| [#246 F-C1](t3-thread://v2/3cd7b447-851e-4bbe-bfb5-04c2d00b549d/thread:delegated-task:command%3Amcp%3Afea13403-ebdb-4226-b85b-876c8e7fe9b6%3Adelegate-task%3A8e508991-cdf0-4d92-be9a-e95a44c8ddd8) | Candidate | `implementation` | 1 | 13.629 | 1.030 | 3.929 | 64.317 |
| [#246 F-B2](t3-thread://v2/3cd7b447-851e-4bbe-bfb5-04c2d00b549d/thread:delegated-task:command%3Amcp%3Afea13403-ebdb-4226-b85b-876c8e7fe9b6%3Adelegate-task%3Ab19fae9d-6070-45ce-bd7e-067b354de28e) | Baseline | `direct` | 0 | 5.417 | — | — | 21.653 |
| [#246 F-C2](t3-thread://v2/3cd7b447-851e-4bbe-bfb5-04c2d00b549d/thread:delegated-task:command%3Amcp%3Afea13403-ebdb-4226-b85b-876c8e7fe9b6%3Adelegate-task%3A3a1b66fb-950f-4e03-8bdf-c73fa4a1661f) | Candidate | `implementation` | 1 | 17.518 | 0.831 | 4.962 | 68.023 |
| [#246 R-B1](t3-thread://v2/3cd7b447-851e-4bbe-bfb5-04c2d00b549d/thread:delegated-task:command%3Amcp%3Afea13403-ebdb-4226-b85b-876c8e7fe9b6%3Adelegate-task%3A7cc5b994-807e-4884-88fd-f8737c55a1da) | Baseline | `direct` | 0 | 6.425 | — | — | 28.041 |
| [#246 R-C1](t3-thread://v2/3cd7b447-851e-4bbe-bfb5-04c2d00b549d/thread:delegated-task:command%3Amcp%3Afea13403-ebdb-4226-b85b-876c8e7fe9b6%3Adelegate-task%3Aca748327-f638-496d-9e7f-874ca0f019bb) | Candidate | `review` | 1 | 11.375 | 0.543 | 7.174 | 61.022 |
| [#246 R-B2](t3-thread://v2/3cd7b447-851e-4bbe-bfb5-04c2d00b549d/thread:delegated-task:command%3Amcp%3Afea13403-ebdb-4226-b85b-876c8e7fe9b6%3Adelegate-task%3Ab0cd79cc-71a0-455d-9a70-df9c197ecb31) | Baseline | `direct` | 0 | 3.148 | — | — | 16.902 |
| [#246 R-C2](t3-thread://v2/3cd7b447-851e-4bbe-bfb5-04c2d00b549d/thread:delegated-task:command%3Amcp%3Afea13403-ebdb-4226-b85b-876c8e7fe9b6%3Adelegate-task%3A82c64aa3-835e-4383-8a3f-52c3b76dedd1) | Candidate | `review` | 1 | 14.456 | 0.984 | 11.916 | 87.153 |
| [#246 S-B1](t3-thread://v2/3cd7b447-851e-4bbe-bfb5-04c2d00b549d/thread:delegated-task:command%3Amcp%3A0ed70548-5d0a-4d9e-a535-7885878b50de%3Adelegate-task%3Aebaeaa05-bd3f-4fa3-8aef-c0856a95af7a) | Baseline | `direct` | 0 | 5.183 | — | — | 19.465 |
| [#246 S-C1](t3-thread://v2/3cd7b447-851e-4bbe-bfb5-04c2d00b549d/thread:delegated-task:command%3Amcp%3A0ed70548-5d0a-4d9e-a535-7885878b50de%3Adelegate-task%3A8100a6be-0c0c-42d2-81e6-01c4c685f384) | Candidate | `implementation` | 1 | 13.795 | 1.293 | 3.765 | 55.910 |
| [#246 S-C2](t3-thread://v2/3cd7b447-851e-4bbe-bfb5-04c2d00b549d/thread:delegated-task:command%3Amcp%3A0ed70548-5d0a-4d9e-a535-7885878b50de%3Adelegate-task%3A8c773e9c-8763-42c8-bb52-592f4f413a6a) | Candidate | `implementation` | 1 | 11.187 | 0.468 | 3.625 | 49.192 |
| [#246 S-B2](t3-thread://v2/3cd7b447-851e-4bbe-bfb5-04c2d00b549d/thread:delegated-task:command%3Amcp%3A0ed70548-5d0a-4d9e-a535-7885878b50de%3Adelegate-task%3A608a3aad-3072-4769-9001-a5254352839c) | Baseline | `direct` | 0 | 2.192 | — | — | 14.303 |

The baseline called judge zero times. Each candidate trial called it once
and launched the returned role without a second judgment. All six children
returned usable results. The baseline missed both independent review
opportunities and made zero unnecessary delegations. The candidate took
both review opportunities and made four unnecessary delegations, two for
the coupled fix and two for the short edit. Under the rubric, the baseline
had two mismatches in six trials and the candidate had four in six.

Both arms returned all six correct substantive outputs. All four coupled fix
outputs preserved the caller behavior and returned the new parser
representation. All review outputs had the right tally and both defects.
Baseline trial R-B2 split the zero-filter defect into two rows, supplying
three examples for two root causes. All three examples were valid. Both
short-edit baseline trials ran directly. Both candidate judgments selected
`implementation` with confidence 0.7624 and both workers completed. All
four trial outputs changed only the requested string. Neither arm missed
a delegation opportunity on the short edit.

On the short edit, the candidate took 8.612 s and 8.995 s longer to decide
and 36.445 s and 34.889 s longer to finish in the first and second pairs,
respectively.

The median decision time was 5.300 s for the baseline and 13.712 s for the
candidate. The candidate was slower to decide in each pair by 4.950–12.101 s.
The judge calls themselves took 0.468–1.293 s. Decision time also includes
the model's tool discovery, request construction and interpretation before
the recorded route. Child results took 3.625–11.916 s from launch to return.
Each candidate trial also took longer overall. Both paired candidate review
trials awaited the reviewer before returning a tally.

### Bypass and fallback controls

Four additional candidate sessions ran the same review fixture. The explicit
requirement launched one reviewer. The explicit prohibition ran inline.
Both bypassed judge.

| Trial trace | Control | Live judge calls | Route | Children | Decision (s) | Child (s) |
| --- | --- | ---: | --- | ---: | ---: | ---: |
| [#246 R-REQ](t3-thread://v2/3cd7b447-851e-4bbe-bfb5-04c2d00b549d/thread:delegated-task:command%3Amcp%3Afea13403-ebdb-4226-b85b-876c8e7fe9b6%3Adelegate-task%3A3948c6a3-769d-4a60-a112-79244e84f36d) | Required review | 0 | `review` | 1 | 6.728 | 13.506 |
| [#246 R-PRO](t3-thread://v2/3cd7b447-851e-4bbe-bfb5-04c2d00b549d/thread:delegated-task:command%3Amcp%3Afea13403-ebdb-4226-b85b-876c8e7fe9b6%3Adelegate-task%3A4d8d3ec7-f4da-46f9-9549-056b3eb036ea) | Prohibited delegation | 0 | `direct` | 0 | 2.504 | — |
| [#246 R-ABS](t3-thread://v2/3cd7b447-851e-4bbe-bfb5-04c2d00b549d/thread:delegated-task:command%3Amcp%3Afea13403-ebdb-4226-b85b-876c8e7fe9b6%3Adelegate-task%3A0ab88558-d277-48db-b090-6183ab84c286) | Injected `insufficient_evidence` | 0 | `review` | 1 | 13.594 | 14.426 |
| [#246 R-ERR](t3-thread://v2/3cd7b447-851e-4bbe-bfb5-04c2d00b549d/thread:delegated-task:command%3Amcp%3Afea13403-ebdb-4226-b85b-876c8e7fe9b6%3Adelegate-task%3A76f26758-b2bc-46b4-8795-68782a713755) | Injected unsupported model | 1 | `review` | 1 | 14.768 | 12.815 |

The abstention control injected one `insufficient_evidence` response at the
tool boundary. The failure control sent one live MCP request with the
unsupported model `mlx-community/eval-246-unsupported`. The local tool
returned `400: Model is not supported by this backend` in 0.020 s. In both
cases the parent applied the baseline workflow and selected the sole
eligible review role using its own judgment. Both children finished and
both parents returned the tally and findings.

### Verification and limits

The linked trial records contain the routes, child links and outputs. Native
Codex tool records confirmed the judge calls, safe request inputs and launch
counts. T3 recorded each child's role preamble and terminal state. F-C1
and S-C1 outlasted the 55-second outer wait. Both finished on the original
runs, which supply the recorded trial times.

A separate Python check executed all four submitted fixes against the original
caller on 1,446 accepted strings, including every minute of a day, and
compared five parsing failures per fix. It also replayed the status tally
and every reported counterexample from the eight review outputs. For the
short edit, a Python check compared the four trial outputs and two worker
outputs against the requested one-string change and exercised both branches.
All checks passed.

The result covers three small fixtures, one Codex route and one warm local
judge. The routing rubric assigns equal weight to the two kinds of mismatch.
Effects across workloads and benefits from overlapping review with parent
work remain unmeasured.

## Preliminary evidence

In the preliminary evaluation at `0980e3e`, the existing local decide
service reported the MLX backend and
`mlx-community/clef-flash-8bit`. A cold synthetic choice took 10.318 seconds,
including model loading. Twelve subsequent MCP calls took 0.482–0.536 seconds
each. Each of six nonsensitive scenarios was submitted twice with direct work,
research, review and abstention as choices. Both repetitions returned the same answer.

| Scenario | Choice |
| --- | --- |
| One known typo | Direct |
| One known constant | Direct |
| Parser and coupled caller | Direct |
| Function rename and coupled callers | Direct |
| Independent research alongside implementation | Research |
| Independent review alongside implementation | Review |

These choices matched the evaluator's expected routes: zero apparent missed or
unnecessary delegations out of six scenarios under that subjective rubric.
The repetitions measured choices. The preliminary runs used illustrative
roles and had no baseline trials with the session's verified role catalog.
The paired short-edit candidates had an eligible `implementation` role
and selected it in both repetitions.

One native child reviewed a synthetic average function and correctly identified
an incorrect denominator. The preliminary run timed neither the child nor a
paired direct execution.
