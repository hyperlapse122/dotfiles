# dotagents/

**Generated:** 2026-04-03 | **Commit:** 389a20b | **Branch:** main

Linked to `~/.agents` via Dotbot. Contains AI agent skills managed by OpenCode's skill system.

## STRUCTURE

```text
dotagents/
├── .skill-lock.json        # Lockfile tracking installed skill versions
└── skills/                 # One directory per skill
    ├── cloudflare/         # Cloudflare Workers, Pages, KV, D1, R2, AI
    ├── docx/               # Word document creation/manipulation
    ├── durable-objects/    # Cloudflare Durable Objects
    ├── find-skills/        # Skill discovery helper
    ├── git-flow-branch-creator/ # Git Flow branch naming
    ├── neon-postgres/      # Neon Serverless Postgres
    ├── pdf/                # PDF read/write/merge/split
    ├── playwright-cli/     # Browser automation and testing
    ├── pptx/               # PowerPoint creation/manipulation
    ├── skill-creator/      # Create and optimize skills
    ├── turborepo/          # Turborepo monorepo guidance
    ├── vercel-composition-patterns/ # React composition patterns
    ├── vercel-react-best-practices/ # React/Next.js performance
    ├── vercel-react-native-skills/  # React Native/Expo
    ├── vercel-react-view-transitions/ # React View Transitions API
    ├── web-design-guidelines/ # Web UI/UX review
    ├── web-perf/           # Web performance auditing
    ├── workers-best-practices/ # CF Workers production patterns
    ├── wrangler/           # Cloudflare Workers CLI
    └── xlsx/               # Spreadsheet creation/manipulation
```

## CONVENTIONS

- Each skill contains a `SKILL.md` entry point and optional `references/`, `rules/`, `scripts/` subdirs.
- Skills are **managed artifacts** — installed/updated via OpenCode's skill system, not manually edited.
- `.skill-lock.json` tracks versions; do not edit by hand.
- Some skills (docx, pptx, xlsx) bundle Office XML schemas under `scripts/office/schemas/` — these are large and read-only.

## ANTI-PATTERNS

| Forbidden | Why |
|-----------|-----|
| Hand-edit `.skill-lock.json` | Managed by skill system; manual edits cause sync issues |
| Modify skill contents directly | Use `skill-creator` skill to update; direct edits get overwritten |
| Add non-skill files under `skills/` | Reserved for the skill system directory structure |
