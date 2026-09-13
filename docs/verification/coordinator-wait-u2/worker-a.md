# U2 question stimulus

You are one read-only test worker. The coordinator is testing its user-scoped
wait instructions. You must not edit files, install tools, change permissions,
run Git mutations, launch agents, or create another Run.

Use `orca-ide` for every Orca command, never bare `orca`. Preserve the live
preamble's exact identity and capability arguments. Your hard deadline is ten
minutes from dispatch. Report failure before that deadline if blocked.

After reading applicable standing instructions, run one native command `sleep
90`. This fixed delay is the test stimulus, not a coordinator wait, a poll, or a
loop. Keep its native handle until it finishes. Then use the preamble's blocking
ask command to ask your coordinator `U2_A_QUESTION: may this read-only fixture
finish?`. Use a 120000 ms ask timeout; if it expires, resume the same question
ID, never send a duplicate. You must receive `U2_PROCEED` before reporting
success. Immediately before completion, perform the required inbox checkpoint.
Send exactly one valid `worker_done` with explicit outcome and both lifecycle
IDs, then idle. Report the delay, question/reply IDs, and that you edited no file.
