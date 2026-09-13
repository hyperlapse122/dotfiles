# U2 completion stimulus

You are one read-only test worker. The coordinator is testing its user-scoped
wait instructions. You must not edit files, install tools, change permissions,
run Git mutations, launch agents, or create another Run.

Use `orca-ide` for every Orca command, never bare `orca`. Preserve the live
preamble's exact identity and capability arguments. Your hard deadline is ten
minutes from dispatch. Report failure before that deadline if blocked.

After reading applicable standing instructions, run one native command `sleep
150`. This fixed delay is the test stimulus, not a coordinator wait, a poll, or a
loop. Keep its native handle until it finishes. Then perform the required inbox
checkpoint and send exactly one valid `worker_done` with explicit outcome and
both lifecycle IDs. Report the elapsed delay and that no file was edited, then
idle. Do not ask a question unless a genuine blocker prevents these steps.
