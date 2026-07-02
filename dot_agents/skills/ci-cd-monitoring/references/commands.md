# CI/CD CLI recipes — reference

## Wait with ONE native blocking command (do NOT loop one-shot polls as separate tool calls, do NOT use shell scripts)

Run **a single** native CLI command that returns only when the pipeline reaches a terminal
state. Use the built-in `--watch` / `--live` blocker for the platform. Never re-run a
one-shot status command as repeated tool calls to fake waiting, and never wrap one-shot
commands in a shell `while`/`sleep` loop — shell polling is prohibited.

```bash
# GitHub — native blockers (already wait to completion; non-zero exit on failure)
# https://cli.github.com/manual/gh_run_watch
gh run watch <run-id> --exit-status                         # blocks on ONE run; exit 1 if it fails
gh pr checks <num> --watch --fail-fast                      # blocks on ALL checks for the PR

# GitLab — native blocker for the CURRENT branch's latest pipeline (the ONLY sanctioned monitor)
# Continuously updates status in the terminal and exits non-zero on failure.
# https://gitlab.com/gitlab-org/cli/-/raw/main/docs/source/ci/status.md
# MUST monitor with --live. MUST NOT use the --jq flag, pipe glab through `| jq`,
# or pass -F/--output json (--json) for GitLab CI — see the prohibition below.
glab ci status --live
```

If you need to monitor a specific pipeline by ID on GitLab and `glab ci status --live` does
not cover it, use `glab ci get --pipeline-id <id>` only for one-shot inspection after the
pipeline has reached a terminal state — not for polling.

## One-shot status / log inspection (for diagnosis, NOT for waiting)

```bash
# GitHub
gh run list --branch "$(git branch --show-current)" --limit 5
gh run view <run-id> --log-failed                           # failed-job logs only

# GitLab — text output only; NEVER --jq, NEVER -F/--output json (--json), NEVER pipe through `| jq`
glab ci status                                              # current branch's pipeline summary (one-shot, text)
glab ci status --live                                       # PREFERRED: block until the pipeline finishes, exit non-zero on failure
glab ci view                                                # interactive pipeline view (humans, not agents)
glab ci get                                                 # current branch's pipeline details (text)
glab ci get --pipeline-id <id>                              # one pipeline by ID (text)
glab ci get --merge-request <iid>                           # an MR's head pipeline (text; handles forks/detached)
glab ci get --merge-request <iid> --status failed --with-job-details  # only the failed jobs, with detail
glab ci trace <job-id>                                      # stream a single job's log
```

GitLab pipeline statuses shown in the `glab ci status` / `glab ci get` text output:
non-terminal `created`, `waiting_for_resource`, `preparing`, `pending`, `running`; terminal
`success`, `failed`, `canceled`, `skipped`, `manual`, `scheduled`.

## Terminal vs. non-terminal states

- **Terminal** (stop polling): `success`, `failure`, `cancelled`, `timed_out`,
  `action_required`.
- **Non-terminal** (keep polling): `pending`, `queued`, `running`, `in-progress`.
