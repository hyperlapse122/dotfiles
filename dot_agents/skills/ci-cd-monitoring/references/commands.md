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

# GitLab — native blocker for the CURRENT branch's latest pipeline
# Continuously updates status in the terminal and exits non-zero on failure.
# https://gitlab.com/gitlab-org/cli/-/raw/main/docs/source/ci/status.md
# NOTE: --live is mutually exclusive with --output json and --compact.
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

# GitLab
glab ci status                                              # current branch's pipeline summary (one-shot)
glab ci status --output json | jq -r 'if type == "array" then .[0].pipeline.status else .pipeline.status end'  # pipeline status from one-shot JSON (shape varies by state)
glab ci status --live                                       # block until the pipeline finishes, exit non-zero on failure
glab ci view                                                # interactive pipeline view (humans, not agents)
glab ci trace <job-id>                                      # stream a job's log
glab ci get --pipeline-id <id> --output json \             # one pipeline by ID — full schema
  | jq '{id, iid, status, source, ref, web_url, jobs: [.jobs[] | {name, stage, status}]}'
glab api "projects/$PROJECT/merge_requests/$MR_IID/pipelines" \
  | jq '.[0] | {id, status, sha, web_url}'
```

Pipeline `status` enum (the `.status` field above): non-terminal `created`,
`waiting_for_resource`, `preparing`, `pending`, `running`; terminal `success`, `failed`,
`canceled`, `skipped`, `manual`, `scheduled`. `detailed_status.group` collapses to the same
buckets and is handy for a coarse pass/fail check.

`$PROJECT` is the slash-separated project path (never URL-encoded); prefer `:fullpath` when
the repo remote points at the target.

## Terminal vs. non-terminal states

- **Terminal** (stop polling): `success`, `failure`, `cancelled`, `timed_out`,
  `action_required`.
- **Non-terminal** (keep polling): `pending`, `queued`, `running`, `in-progress`.
