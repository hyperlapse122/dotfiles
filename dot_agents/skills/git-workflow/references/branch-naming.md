# Branch naming — reference

## Forbidden branch-name shapes (all caught by the same gate)

The list below is **illustrative**, not exhaustive. The single rule is "**MUST start with
a Git Flow prefix**" — anything that fails that rule is forbidden, regardless of how it
was created.

| Shape | Example | Why it fails |
|---|---|---|
| OpenCode auto-generated | `opencode/playful-engine` | No Git Flow prefix |
| Codex auto-generated | `codex/dapper-otter` | No Git Flow prefix |
| agent-of-empires (aoe) auto-generated | `Koreans`, `Japaneses`, `Aztecs` | No Git Flow prefix (civilization codename, not a slug) |
| GitLab issue button / `glab issue develop` | `13-feat-requester-rebuild` | Numeric prefix, not Git Flow |
| GitHub *Development → Create a branch* / `gh issue develop` | `42-add-auth` | Numeric prefix, not Git Flow |
| **Bare human-authored slug** | `add-auth`, `fix-login`, `adding-figma-mcp`, `cleanup-deps` | **No Git Flow prefix — same severity as auto-generated** |
| IDE / tool placeholder | `branch1`, `wip`, `temp`, `test` | No Git Flow prefix |
| Any other tool-generated placeholder | (varies) | No Git Flow prefix |

A bare human-authored slug is **just as forbidden** as an auto-generated name. Do not
assume "I picked it manually, so it's fine" — the gate rejects shape, not provenance.

## Rename recipes

```bash
git branch --show-current                                  # always run this first
git branch -m opencode/playful-engine feature/add-auth     # ✅ rename in place (auto-generated → prefix)
git branch -m codex/dapper-otter      bugfix/login-500     # ✅ rename in place (auto-generated → prefix)
git branch -m adding-figma-mcp        feature/figma-mcp    # ✅ rename in place (bare slug → prefix)
git branch -m 13-feat-requester       feature/requester-rebuild  # ✅ rename in place (numeric → prefix)
git checkout -b feature/add-auth                           # ❌ leaves the old branch orphaned
```

## Naming convention (Git Flow)

Unless the project defines its own equivalent set:

| Prefix | Use for | Matching commit type |
|---|---|---|
| `feature/` | New features | `feat` |
| `bugfix/` | Bug fixes | `fix` |
| `hotfix/` | Urgent production fixes | `fix` |
| `refactor/` | Code restructuring | `refactor` |
| `docs/` | Documentation | `docs` |
| `chore/` | Maintenance / config / deps / tooling | `chore` |
| `release/` | Release preparation | n/a |

Slug **MUST** be a 3–6 word human-authored summary — not the full issue title, not the
issue number, not a single word, not a placeholder. Words separated by `-`.

**One task = one branch.** Name needs changing → rename it. **MUST NOT** create a sibling
branch for the same work.
