---
name: ship-issue
description: End-to-end issue automation — triage (or re-triage) a GitHub/GitLab issue, work item, or MR; implement the fix; push directly on the default branch or open a PR/MR; then monitor GitHub Actions / GitLab CI/CD and self-heal until the pipeline goes green. Triggers on phrases like "check <issue/MR/work-item URL> and create PR/MR for fix", "ship this issue", "triage and fix <URL>", "monitor pipeline and fix until green", or any single URL pointing at a GitHub issue/PR or GitLab issue/work_item/merge_request.
---

# ship-issue

End-to-end automation: take a single GitHub/GitLab URL (issue, work item, PR, or MR) and drive it to a green pipeline on the default branch.

The user prompt usually looks like:

> check `<URL>` and create MR for fix. monitor pipeline and fix pipeline until pipeline goes green

or any subset thereof. Treat a bare URL as the same intent.

**Load skills first.** Before doing host operations:

- GitHub URL → load `gh-cli` via the `skill` tool.
- GitLab URL → load `glab` via the `skill` tool.
- Both also use `git-master` for branch/commit/rebase hygiene — load it.

**Always read `~/.config/opencode/AGENTS.md`** (or in-context if already injected) before opening a PR/MR. The branch-naming, source-branch substitution trap, and assignment rules in that file are mandatory and override anything below if they conflict.

## Phase 0 — Parse the URL

Classify the URL into one of:

| Pattern | Host | Kind |
|---|---|---|
| `https://github.com/<owner>/<repo>/issues/<N>` | GitHub | issue |
| `https://github.com/<owner>/<repo>/pull/<N>` | GitHub | PR |
| `https://<gitlab-host>/<group>/<project>/-/issues/<N>` | GitLab | issue |
| `https://<gitlab-host>/<group>/<project>/-/work_items/<N>` | GitLab | work item |
| `https://<gitlab-host>/<group>/<project>/-/merge_requests/<N>` | GitLab | MR |

Capture: `host`, `kind`, `owner|group`, `repo|project`, `id` (`N`).

If the URL does not match any pattern, **STOP** and ask the user what they meant. Do not guess.

## Phase 1 — Locate the repo on disk

The user runs this command from a working directory. Verify it is the matching git repo:

```bash
git rev-parse --show-toplevel
git config --get remote.origin.url        # also try remote.upstream.url
```

The remote URL MUST point at the same `<owner>/<repo>` (GitHub) or `<group>/<project>` (GitLab) extracted in Phase 0. If it does not:

- If a sibling clone is obvious (e.g. `~/src/<repo>`), `cd` there with the `workdir` parameter.
- Otherwise STOP and ask the user which checkout to use. Do not clone speculatively.

Determine the default branch:

```bash
git remote show origin | sed -n 's/.*HEAD branch: //p'
```

Cache as `DEFAULT_BRANCH`. All later logic gates on this.

## Phase 2 — Triage (always from scratch)

Per user contract: **always re-triage from scratch**, even when the issue body already has detail. Add more context, do not assume the existing description is exhaustive.

### 2a. Fetch the issue/work-item/MR

**GitHub issue/PR:**

```bash
gh issue view <N> --repo <owner>/<repo> --json title,body,labels,assignees,state,comments,milestone
gh issue view <N> --repo <owner>/<repo> --comments
# For PRs, swap `issue view` → `pr view` and also fetch the diff:
gh pr view <N> --repo <owner>/<repo> --json title,body,labels,headRefName,baseRefName,state,commits
gh pr diff <N> --repo <owner>/<repo>
```

**GitLab issue:**

```bash
glab issue view <N> -R <group>/<project> --comments
```

**GitLab work item** (a separate API surface from classic issues — `glab issue view` may not resolve a `work_items/<N>` URL). Fall back to the REST API via `glab api`:

```bash
PROJECT_ENC=$(printf '%s' '<group>/<project>' | sed 's|/|%2F|g')
glab api "projects/$PROJECT_ENC/work_items/<N>" | jq .
glab api "projects/$PROJECT_ENC/work_items/<N>/notes"  | jq -r '.[].body'
```

If the work-item endpoint returns 404 (older GitLab versions or non-work-item types), retry as a classic issue: `glab issue view <N> -R <group>/<project> --comments`.

**GitLab MR:**

```bash
glab mr view <N> -R <group>/<project> --comments
glab mr diff <N> -R <group>/<project>
```

### 2b. Gather codebase context

Now triage from scratch. In parallel, fan out **before** writing any fix:

- `explore` agent — find the modules/files implicated by the issue title, error messages, stack traces, or screenshots referenced.
- `librarian` agent — only if an external library is named or an unfamiliar framework feature is involved.
- Read the implicated files directly once `explore` has narrowed scope.

If the issue has linked Figma URLs, **MUST** use the Figma MCP to fetch the latest design (re-fetch every time per the user's global agent rules). Do not skip this step.

### 2c. Produce the triage note

Before touching code, produce a short structured triage block (post it as a comment when running unattended is OK; otherwise just keep it in context):

```
## Triage
- **Kind**: bug | feat | docs | chore | …
- **Root cause hypothesis**: …
- **Affected files**: path/to/a.ts, path/to/b.ts
- **Scope**: what is and is NOT in scope
- **Acceptance criteria**: bullet list of observable conditions for "fixed"
- **Verification plan**: how the fix will be proven (which tests / which manual flow)
- **Risk / rollback**: side effects, feature flags, migrations
```

If the issue is genuinely too thin to act on, **STOP** and post a triage comment asking the missing questions instead of guessing. Use:

```bash
# GitHub
gh issue comment <N> --repo <owner>/<repo> --body-file -

# GitLab classic issue
glab issue note <N> -R <group>/<project> --message "$(cat note.md)"

# GitLab work item — use the work-items notes endpoint
glab api -X POST "projects/$PROJECT_ENC/work_items/<N>/notes" --field body=@note.md
```

Then end the run and wait for the reporter.

## Phase 3 — Branch + implement

### 3a. Pick the branch

```bash
git branch --show-current
```

- If current branch == `$DEFAULT_BRANCH` **and** the change is genuinely trivial (single-line fix, doc typo) **and** the user explicitly invited a direct push ("just push", "push directly", "on main"), stay on the default branch — Phase 4 will push instead of opening a PR/MR.
- Otherwise, create a Git Flow branch from `$DEFAULT_BRANCH`:

```bash
git fetch origin
git switch -c <prefix>/<short-slug> origin/$DEFAULT_BRANCH
```

`<prefix>` is `feature/`, `bugfix/`, `hotfix/`, `refactor/`, `docs/`, or `chore/` per the issue kind. `<short-slug>` is a 3–6 word human-authored summary — **never** the issue number, **never** the raw issue title.

If you are already on a host-fabricated branch (`opencode/...`, `codex/...`, GitLab's `<N>-<issue-slug>`, GitHub's `<N>-<slug>`), **rename in place** before any commit:

```bash
git branch -m <prefix>/<short-slug>
```

Do this **before** the first commit. Renaming after pushing leaks the bad name into history.

### 3b. Implement

- Match the codebase's existing style (sample 2–3 similar files first).
- Smallest correct change wins. Bug fix ≠ refactor.
- Run the project's lint / typecheck / test / build commands locally before committing. The pre-PR gate in `~/.config/opencode/AGENTS.md` is non-negotiable.

### 3c. Commit

Conventional Commits, lowercase imperative subject, no AI-tool attribution, no emojis:

```bash
git add -A
git commit -m "fix(<scope>): <description>"
```

If the fix spans multiple logical concerns, split into multiple commits. Reference the issue in the **body**, not the subject, using a closing keyword the host will auto-action on merge:

```
fix(auth): handle expired refresh tokens

Closes #25
```

GitHub keywords that auto-close: `Close[s|d]`, `Fix[es|ed]`, `Resolve[s|d]`.
GitLab keywords that auto-close: `Close[s|d|ing]`, `Fix[es|ed|ing]`, `Resolve[s|d|ing]`, `Implement[s|ed|ing]`.

**Work items**: GitLab work items currently do not auto-close from MR-description keywords on all instances. If the URL was a work-item URL, plan to close it manually in Phase 5 via the API.

## Phase 4 — Push, PR/MR (or direct push)

### 4a. Direct push branch (only when staying on `$DEFAULT_BRANCH`)

```bash
git push origin "$(git branch --show-current)"
```

Skip to Phase 5. CI runs from the default-branch push.

### 4b. Feature branch — open the PR/MR

Push the branch first, with upstream:

```bash
git push -u origin "$(git branch --show-current)"
```

Verify the worktree is clean and the local branch matches the remote:

```bash
git status                                          # MUST be clean
git log @{u}..                                      # MUST be empty
```

Then create the PR/MR. **MUST** pin the source branch explicitly. **MUST NOT** pass `--related-issue` (glab) or `--issue` (gh) — both trigger the source-branch substitution trap documented in `~/.config/opencode/AGENTS.md`. Link the issue **only** via a closing keyword inside the body.

**GitHub:**

```bash
gh pr create \
  --head "$(git branch --show-current)" \
  --base "$DEFAULT_BRANCH" \
  --assignee @me \
  --title "fix(<scope>): <description>" \
  --body "$(cat <<'EOF'
## Summary
…

## Verification
…

Closes #<N>
EOF
)"
```

**GitLab:**

```bash
glab mr create \
  --source-branch "$(git branch --show-current)" \
  --target-branch "$DEFAULT_BRANCH" \
  --assignee "$(glab api user | jq -r '.username')" \
  --remove-source-branch \
  --title "fix(<scope>): <description>" \
  --description "$(cat <<'EOF'
## Summary
…

## Verification
…

Closes #<N>
EOF
)"
```

Do not open as draft unless the user asked for it.

### 4c. Verify the PR/MR is real

The create call does not fail when the source branch was substituted. Verify immediately:

```bash
# GitHub
gh pr view <NUM> --json headRefName,commits \
  | jq '{headRefName, commit_count: (.commits | length)}'

# GitLab
PROJECT_ENC=$(printf '%s' '<group>/<project>' | sed 's|/|%2F|g')
glab api "projects/$PROJECT_ENC/merge_requests/<IID>" \
  | jq '{source_branch, head_sha: .diff_refs.head_sha, base_sha: .diff_refs.base_sha}'
glab api "projects/$PROJECT_ENC/merge_requests/<IID>/commits" | jq 'length'   # MUST be > 0
```

`headRefName` / `source_branch` MUST match the locally pushed Git Flow branch. Commit count MUST be `> 0`. `head_sha != base_sha`.

If the source branch matches `^[0-9]+-` (GitLab) or `^[0-9]+-[a-z]` (GitHub), the PR/MR is broken:

1. Close it (`gh pr close <NUM>` / `glab mr close <IID>`).
2. Delete the stray remote branch (`git push origin --delete <N>-<slug>`).
3. Re-run Phase 4b with the source branch pinned correctly.

Cache the PR/MR number (`PR_NUM` for GitHub, `MR_IID` for GitLab) and the head SHA — Phase 5 needs them.

## Phase 5 — Monitor the pipeline and self-heal

Loop until the pipeline on the latest pushed commit is green or until an explicit failure budget is exhausted.

### 5a. Watch checks

**GitHub Actions:**

```bash
# Direct-push case (no PR): poll runs for this commit
gh run list --branch "$DEFAULT_BRANCH" --limit 5 --json databaseId,headSha,status,conclusion,name,event \
  | jq '.[] | select(.headSha=="'"$HEAD_SHA"'")'

# PR case: block until checks complete
gh pr checks <PR_NUM> --watch
gh pr checks <PR_NUM> --json name,state,bucket,link
```

**GitLab CI/CD:**

```bash
# MR case
glab mr view <MR_IID> -R <group>/<project>           # quick text view
glab ci status --branch "$(git branch --show-current)"
# Or stream:
glab ci view --branch "$(git branch --show-current)"

# Direct-push case (default branch)
glab ci status --branch "$DEFAULT_BRANCH"
```

For unattended polling, prefer the JSON form via `glab api`:

```bash
PROJECT_ENC=$(printf '%s' '<group>/<project>' | sed 's|/|%2F|g')
# Latest pipeline for the current branch
glab api "projects/$PROJECT_ENC/pipelines?ref=$(git branch --show-current)&per_page=1" | jq '.[0]'
# Jobs for that pipeline
glab api "projects/$PROJECT_ENC/pipelines/<PIPELINE_ID>/jobs" | jq '.[] | {id, name, stage, status}'
```

### 5b. If green — done

GitHub success: every check's `bucket == "pass"` (or `state == "SUCCESS"`).
GitLab success: pipeline `status == "success"`.

Report green to the user and exit the loop. The PR/MR is ready for human review; do **not** merge it unless the user explicitly asked. The merge is a separate, human-gated step.

### 5c. If red — diagnose and fix

For each failing job:

**GitHub:**

```bash
gh run view <RUN_ID> --log-failed                       # only failed step logs
gh run view <RUN_ID> --log | tail -n 500                # full log tail
```

**GitLab:**

```bash
glab ci trace --branch "$(git branch --show-current)"   # tail of running/last job
glab api "projects/$PROJECT_ENC/jobs/<JOB_ID>/trace" | tail -n 500
```

Then:

1. Parse the failure. Group failures: lint, typecheck, test, build, infra/transient.
2. **Infra/transient** (runner offline, dependency mirror timeout, flake) → re-run only that job:
   - GitHub: `gh run rerun <RUN_ID> --failed`
   - GitLab: `glab api -X POST "projects/$PROJECT_ENC/jobs/<JOB_ID>/retry"`
3. **Real failure** → reproduce locally if possible, fix, commit (Conventional Commits), push:

   ```bash
   git add -A
   git commit -m "fix(ci): <what>"
   git push
   ```

   Pushing updates the PR/MR head SHA. Loop back to Phase 5a with the new SHA.
4. **Failure budget**: after **3 consecutive** push-fix-fail cycles on the same job, STOP. Summarize attempts to the user, link the failing run, and ask before continuing. Do not blindly thrash.

Never delete failing tests to make the pipeline green. Never disable a check with `--no-verify`, `[skip ci]`, or job allow-list edits without explicit user approval.

### 5d. Issue/work-item linkage on completion

If the URL was a **GitLab work item** and the PR/MR's closing keyword does not auto-close work items on this instance, close it manually after merge:

```bash
glab api -X PATCH "projects/$PROJECT_ENC/work_items/<N>" --field state_event=close
```

(The user normally does this; only do it yourself if the user explicitly asked for the end-to-end close.)

## Stop conditions

End the run and report to the user when **any** of these is true:

- Pipeline is green (success path).
- Failure budget exhausted (3 consecutive failed fix attempts on the same job).
- A required step needs human judgment: secret rotation, migration rollback, destructive cleanup, prod deploy gate.
- The issue is too thin to act on (no repro, no acceptance criteria) — post a triage comment and stop.

## Hard rules (project-wide, copied here for visibility)

- **MUST NOT** use GitLab's `glab mr create --related-issue` or GitHub's `gh pr create --issue`. They trigger the source-branch substitution trap.
- **MUST NOT** keep, commit on, or push a host-fabricated branch name (`opencode/*`, `codex/*`, `<N>-<slug>`). Rename with `git branch -m` before the first commit.
- **MUST** pin `--head` (gh) / `--source-branch` (glab) explicitly on every PR/MR create.
- **MUST** verify the PR/MR after creation (`commits > 0`, `headRefName` / `source_branch` matches local).
- **MUST** assign the PR/MR to the authenticated user.
- **MUST NOT** open as draft unless the user asked.
- **MUST NOT** commit secrets (`.env`, private keys, tokens) even transiently.
- **MUST NOT** run destructive shortcuts (`--no-verify`, `--force` to shared branches, history rewrite on pushed commits, `[skip ci]`) without explicit user request.
- **MUST** match the project's standard verification gate (test / lint / typecheck / build) locally before pushing.

## Output to the user

Keep updates terse — one line per phase transition is enough during long runs. At the end, report:

```
Triage: <one-line root cause>
Fix:    <commit subject(s)>
PR/MR:  <url> (#<NUM/IID>)
CI:     <green | red after N attempts — link to last failing job>
```

If green, the run is done. The merge is the user's call.
