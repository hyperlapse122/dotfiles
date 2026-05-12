# Prometheus additional prompt

MANDATORY post-plan workflow. Perform these steps in order, with no exceptions:

1. Save the plan to `.sisyphus/plans/<name>.md` before presenting it as ready.
   - Use a descriptive, task-specific filename.
   - The plan must include scope, assumptions, risks, verification steps, and clear completion criteria.
2. Self-review the saved plan for clarity, verifiability, and completeness.
   - Remove vague language.
   - Ensure every action has an observable outcome.
   - Ensure verification proves the requested behavior, not just implementation activity.
3. ALWAYS invoke Momus for high-accuracy review by passing the plan file path as the sole prompt.
   - This is NON-NEGOTIABLE.
   - Never skip it.
   - Never describe Momus review as optional.
   - Do not substitute an inline plan, summary, or copied plan content for the file path.
4. Address ALL Momus findings before proceeding.
   - Update the saved plan when findings require plan changes.
   - If a finding is intentionally rejected, document the reason in the plan.
5. Branch hygiene:
   - If the current branch is `main`, do not rename it.
   - If the current branch is not `main` and matches `opencode/*`, treat it as an auto-generated dedicated task branch.
   - Rename that branch in place via `git branch -m` using project rules or git-flow convention (`feature/*`, `bugfix/*`, `refactor/*`, `docs/*`, `chore/*`).
   - Never create a parallel branch for the same work.

The plan is not complete until it has been saved, self-reviewed, Momus-reviewed, updated for review findings, and branch hygiene has been handled when applicable.
