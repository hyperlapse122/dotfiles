# U2 candidate-policy evaluation

The operator authorizes this isolated coordinator to own one new Run and
supervise exactly two read-only Orca workers. You are not a dispatched worker.
The checkout is the canonical source, but you have no file-write, commit,
deployment, permission-change, or branch/worktree-creation authority.

Source plan: docs/plans/2026-09-13-1424-refactor-coordinator-background-waits-plan.md.
U1 is committed at f94900c. This U2 check must use the candidate policy already
loaded at user scope, not replace it with task-context instructions. Preserve
the repository AGENTS.md and normative Orca injection. Read the repository
supplement if it was not loaded. Load the orchestration skill and binary-matched
guide, including coordinator-loop and recovery-and-cleanup references when
needed. Use only `orca-ide`, never bare `orca` or a native subagent launcher.

The goal is actual worker question/completion handling without polling, lost
continuation, or acknowledgement before required release. Record evidence from
actual receipts, not intent. One native command handle is not an Orca Delivery.

1. Create your own Run, with no other terminal's identity, objective
   `U2 candidate coordinator wait policy`. Report its real ID and your exact
   user-scope verification marker.
2. Start exactly two fresh Claude workers on the current worktree through
   `worker-start --agent claude`, with their configured model. Their specs must
   point respectively to `docs/verification/coordinator-wait-u2/worker-a.md` and
   `docs/verification/coordinator-wait-u2/worker-b.md`. Add the explicit instruction
   to read that brief and obey its ten-minute deadline. Record each
   launch receipt without inferring a model from the requested agent.
   Both starts must precede your first worker wait. A failed start requires
   its supported recovery path, not another blind launch. The installed
   Antigravity 1.2.2 worker path lacks hook execution, and Codex hook-trust
   preparation attempted an out-of-sandbox write in the isolated coordinator.
   These mechanical fixtures use Claude; the coordinator itself is the harness
   under evaluation. Do not change permissions or settings to enable a worker.
3. Use your loaded candidate policy to supervise both workers. Answer
   `U2_A_QUESTION` with `U2_PROCEED`. For each accepted completion, release
   that dispatch immediately before acknowledging its Delivery. Continue
   until both settle, then acknowledge the final processed Delivery without
   another wait. Read retention receipts and query once when required. Record
   each wait's native handle, continuation calls or completion notifications,
   actual quiet interval, and reply/release/ack sequence.
4. Once both workers are settled and released, test empty-result handling with
   one zero-worker diagnostic command:
   `orca-ide orchestration check --wait --types "worker_done,escalation,question" --timeout-ms 1000 --json`.
   This short timeout is only a post-dispatch diagnostic, never a replacement
   for the guide's worker wait. Handle its actual result without a fake ack.
   Then run the ordinary native command `sh -c 'exit 7'` once and handle its
   command error without inventing a Delivery or acknowledging a native ID.
5. Confirm no reclaimable workers remain in your Run. Report all IDs, outcomes,
   lifecycle receipt sequence, native call counts, and any deviation from the
   candidate policy. Do not write a report file or emit worker_done yourself.

The whole evaluation has a fifteen-minute bound from Run creation. Each worker
has the ten-minute deadline above. Follow the installed bounded stop/release
procedure if needed. Never weaken approval policy, fabricate a success, or
silently replace an unsupported continuation. End only when no outstanding
worker or native command lacks an ownership decision.
