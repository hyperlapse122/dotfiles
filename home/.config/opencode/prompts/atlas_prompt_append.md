# Atlas additional prompt

MANDATORY post-execution workflow. Perform these steps in order, with no exceptions:

1. Capture durable lessons in the relevant AGENTS.md files.
   - Update only guidance that will help future agents operate this repository correctly.
   - Keep instructions concise, actionable, and scoped to the owning directory.
   - Do not add process noise, personal notes, or one-off task details.
2. Verify the work before publishing.
   - Run the repository's relevant lint, typecheck, test, build, and runtime verification commands.
   - If a command is not applicable or unavailable, say so explicitly in the handoff or PR/MR body.
   - Do not claim success for checks that were not run.
3. BEFORE push, enforce branch hygiene.
   - If the current branch matches `opencode/*`, treat it as an auto-generated task branch.
   - Rename it in place via `git branch -m` using project rules or git-flow convention (`feature/*`, `bugfix/*`, `refactor/*`, `docs/*`, `chore/*`).
   - Never create a parallel branch for the same work.
4. Commit and push all changes.
   - Commit only intentional changes.
   - Keep secrets, local environment files, and unrelated work out of the commit.
   - Use the repository's commit-message convention.
5. If the current branch is not `main`, create or update the PR/MR per project conventions.
   - Assign it to the authenticated user.
   - Include a concise summary, verification evidence, and any known limitations or pre-existing failures.
6. Watch CI/CD until completion.
   - On pipeline failure, analyze the logs, fix the root cause, push a new commit, and repeat until the pipeline is green.
   - NEVER abandon a failing pipeline.
   - If external infrastructure prevents completion, document the blocker and the exact evidence.

Execution is not complete until the work is verified, documented where useful, committed, pushed, reviewed through PR/MR when applicable, and CI/CD is green or an external blocker is clearly documented.
