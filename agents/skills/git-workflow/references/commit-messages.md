# Commit messages — reference

**MUST** follow [Conventional Commits](https://www.conventionalcommits.org/):
`<type>(<scope>)<!>: <description>`.

## Type table

| Type | Use for |
|---|---|
| `feat` | New feature |
| `fix` | Bug fix |
| `docs` | Documentation only |
| `style` | Formatting, whitespace (no logic change) |
| `refactor` | Restructure (no feature/fix) |
| `perf` | Performance improvement |
| `test` | Tests |
| `build` | Build system / dependencies |
| `ci` | CI/CD configuration |
| `chore` | Maintenance |
| `revert` | Reverting a previous commit |

## Rules

- **Subject**: lowercase, imperative, no period, ≤50 chars (≤72 max). **The ENTIRE subject
  MUST be lowercase** — no exceptions for acronyms (`mcp`, `api`, `jwt`, `ssr`, `url`,
  `html`, `css`, `aws`), brand names (`figma`, `github`, `gitlab`, `playwright`,
  `tailwind`, `react`, `vite`), proper nouns, or initialisms. The default commitlint rule
  `subject-case: [2, 'always', 'lower-case']` rejects any uppercase character in the
  subject — preserving case for "real" names will fail the commit-msg hook and CI. If a
  token genuinely must appear in its canonical case for clarity, put it in the body (which
  has no case rule), not the subject.
- **Scope** (optional): module/area — `feat(auth): add jwt refresh`.
- **Body** (optional): explain *why*, not *what*. Wrap at 72 chars.
- **Breaking change**: `!` after type/scope **and** `BREAKING CHANGE:` footer.
- **Trailers**: `Closes #N` / `Fixes #N` (auto-close on merge), `Refs #N` / `Refs !N`
  (link only), `Co-authored-by: Name <email>` (humans only — never an AI).

## Examples

```
feat(auth): add jwt refresh token rotation
feat(api)!: remove deprecated v1 endpoints

BREAKING CHANGE: v1 API endpoints have been removed. Migrate to v2.
```

**MUST NOT**: emojis, sentence case, trailing periods, vague subjects (`update stuff`,
`fix things`, `wip`), AI-tool branding (no "Generated with Claude", no `🤖`, no
`Co-authored-by:` trailers naming an AI).
