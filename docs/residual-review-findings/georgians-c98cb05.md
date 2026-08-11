# Residual Review Findings

- **P2** `.ci/test-omp-agent-reconcile.sh:312` — Upstream fixture is a hand copy nothing pins to the archive.
  - **Evidence:** The test creates a synthetic upstream loader. The `i-have-adhd` release lock resolves a moving `refs/heads/main` source to a SHA. A future lock update can change `rulesAreInContext()` while the synthetic fixture remains unchanged.
  - **Decision gate:** Decide whether a release-lock update must also require an explicit compatibility review of this full-function patch. A static pin assertion would enforce that policy, but it would make automated lock refreshes fail until the patch receives review.
  - **Review source:** `20260811-135041-78283c8c` at `/tmp/compound-engineering-1000/ce-code-review/20260811-135041-78283c8c/review.json`.
