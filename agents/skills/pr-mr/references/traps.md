# PR/MR traps — reference

## Duplicate-create trap

`glab mr create` and `gh pr create` are **not** idempotent. If the create response is lost
(network blip, terminal redraw, conversation reflow, truncation, timeout, MCP hiccup), the
agent has no signal the server already accepted the request. Retrying creates a **second**
MR/PR — the host's dedupe is server-side and races allow both calls to win. `glab` may also
error *after* the server accepted the create, misleading the agent.

**MUST** query for an existing open MR/PR on the source branch **before every** create call:

```bash
# GitLab — non-empty array means an open MR exists; abort the create.
BRANCH=$(git branch --show-current)
PROJECT=$(glab repo view -F json | jq -r '.path_with_namespace')
glab api "projects/$PROJECT/merge_requests?source_branch=$BRANCH&state=opened" \
  | jq '[.[] | {iid, web_url, title}]'

# GitHub — non-empty list means an open PR exists; abort the create.
gh pr list --head "$(git branch --show-current)" --state open --json number,url,title
```

Non-empty result: **STOP**. View/edit/comment on the existing MR/PR instead.

**MUST NOT** retry `glab mr create` / `gh pr create` after any of these without first
re-running the pre-create query:

- Previous output lost, truncated, or interrupted.
- `409 Conflict` (often "Another open merge request already exists for this source branch").
- `glab` printed `Failed to create merge request. Created recovery file: …` — use
  `glab mr create --recover` instead (and only after the pre-create query confirms no MR exists).
- Timeout, MCP transport error, or non-success without a confirmed server-side rejection.
- Previous call hit the source-branch substitution trap (below) — the broken MR/PR **does**
  exist server-side and **MUST** be closed before recreate.

If a duplicate is detected after the fact (two open MRs, same source branch, same head SHA):
keep the **oldest** by `created_at`, note
`glab mr note create <newer-iid> -m "Duplicate of !<older-iid>. Closing."`, then
`glab mr close <newer-iid>` / `gh pr close <newer-num>`. **MUST NOT** delete the source
branch to "fix" the conflict — that destroys the older MR's diff too.

## Source-branch substitution trap

`--related-issue` (glab), `--issue` (gh), and the *Linked issues* UI picker do **not** use
your currently pushed branch. They look up — or auto-create — a host-fabricated
`<N>-<slug>` branch and use **that** as `source_branch`. The real branch is silently
ignored: the MR/PR opens with `commits: []` and `head_sha == base_sha`. The create call
**does not fail**.

**Mitigations**:

- **MUST NOT** pass `--related-issue` to `glab mr create` or `--issue` to `gh pr create`.
- **MUST NOT** use the *Linked issues* UI picker on the create form.
- **MUST** pin the source branch on every create call:

```bash
# GitLab
glab mr create --source-branch "$(git branch --show-current)" --target-branch main ...

# GitHub
gh pr create --head "$(git branch --show-current)" --base main ...
```

**MUST** verify immediately after creation — the create call does not fail when the source
branch is wrong:

```bash
# GitLab — source_branch matches pushed branch; head_sha differs from base_sha; commits > 0
MR_IID=<iid>
PROJECT=$(glab repo view -F json | jq -r '.path_with_namespace')
glab api "projects/$PROJECT/merge_requests/$MR_IID" \
  | jq '{source_branch, head_sha: .diff_refs.head_sha, base_sha: .diff_refs.base_sha}'
glab api "projects/$PROJECT/merge_requests/$MR_IID/commits" | jq 'length'

# GitHub — headRefName matches pushed branch; commit count > 0
gh pr view <num> --json headRefName,commits | jq '{headRefName, commit_count: (.commits | length)}'
```

If `source_branch` / `headRefName` matches `^[0-9]+-` instead of the pushed Git Flow name,
or commit count is `0`: the PR/MR is **broken**. Close it, delete the stray remote branch
(`git push origin --delete <N>-<slug>`), recreate.

A `<N>-<slug>` ref on the remote is the trap's bait — host-auto-created the moment an issue
is referenced, points at the target branch's HEAD, zero commits. Never legitimate. Delete
before retrying.
