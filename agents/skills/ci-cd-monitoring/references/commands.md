# CI/CD CLI recipes — reference

## Poll / watch / fetch failed logs

```bash
# GitHub
gh pr checks <num> --watch                                  # blocks until all checks finish
gh run list --branch "$(git branch --show-current)" --limit 5
gh run watch <run-id>                                       # tail a specific run
gh run view <run-id> --log-failed                           # failed-job logs only

# GitLab
glab ci status                                              # current branch's pipeline summary
glab ci view                                                # interactive pipeline view
glab ci trace <job-id>                                      # stream a job's log
glab api "projects/$PROJECT/merge_requests/$MR_IID/pipelines" \
  | jq '.[0] | {id, status, sha, web_url}'
```

`$PROJECT` is the slash-separated project path (never URL-encoded); prefer `:fullpath` when
the repo remote points at the target.

## Terminal vs. non-terminal states

- **Terminal** (stop polling): `success`, `failure`, `cancelled`, `timed_out`,
  `action_required`.
- **Non-terminal** (keep polling): `pending`, `queued`, `running`, `in-progress`.
