---
name: design-lenses
description: "Refining, hardening, or reviewing an interface people see or operate: layout, typography, color, motion, responsive and native adaptation, copy clarity, empty and error states, onboarding, accessibility, and performance. Read the matching lens reference before the edit or review."
---

# Design Lenses

Each file under `references/` is one lens from impeccable (Apache-2.0, see
`LICENSE` and `NOTICE.md`), installed unchanged. Read the lens that matches the
work, apply it, then check the result against it before calling the work done.

## Pick the lens

| Work | Read |
| --- | --- |
| Any UI edit, however small: the quality floor and absolute bans | `references/craft-floor.md` |
| Surface whose visitor is doing a task (app UI, dashboard, settings, tools) | `references/mode-operate.md`, `references/operate.md` |
| Surface that must persuade (landing, pricing, marketing) | `references/mode-persuade.md` |
| Surface that must be read (docs, articles, changelogs) | `references/mode-read.md` |
| Spacing, grouping, reading order, hierarchy | `references/layout.md` |
| Type scale, fonts, hierarchy in text | `references/typeset.md` |
| Color as hierarchy and meaning | `references/colorize.md` |
| Motion and transitions | `references/animate.md` |
| Too loud | `references/quieter.md` |
| Too bland | `references/bolder.md` |
| Too much on screen | `references/distill.md` |
| Moments of character | `references/delight.md` |
| Final pass before shipping | `references/polish.md` |
| Errors, edge cases, long or missing data, i18n | `references/harden.md` |
| First run, empty states, activation | `references/onboard.md` |
| Labels, errors, and other interface text | `references/clarify.md` |
| Other screen sizes, devices, or platforms | `references/adapt.md`; native apps also `references/adapt.native.md` |
| iOS or Android conventions | `references/ios.md`, `references/android.md` |
| Accessibility, performance, and responsive checks | `references/audit.md`; native apps `references/audit.native.md` |
| Slow interface | `references/optimize.md` |

## Check the result

Run `impeccable detect <changed-dir>` on the affected UI source before calling the work done.
File detection runs offline. Use it as a project check or in CI, outside per-edit hooks.

For a rendered web UI in T3 Code, use its preview tools. In a standalone CLI
session, point `agent-browser` at an already provisioned Chrome executable and a
local page. Use a fresh session and temporary profile. Set the viewport, run a
targeted measurement, then capture one viewport screenshot. Replace the sample
URL and measurement with the page and behavior under review.

```bash
tmp=$(mktemp -d)
session=$(basename "$tmp" | tr '.' '-')
agent-browser --session "$session" --profile "$tmp/profile" \
  --executable-path "$CHROME_EXECUTABLE" open http://127.0.0.1:3000/
agent-browser --session "$session" set viewport 1280 800
agent-browser --session "$session" eval 'document.documentElement.scrollWidth - innerWidth'
agent-browser --session "$session" screenshot ./viewport.png
agent-browser --session "$session" close
rm -r -- "$tmp"
```

## What not to follow

These references assume impeccable's full workflow. The packaged `impeccable detect`
command above is available. Skip steps that do any of the following.

- Run `npx impeccable` or a script under `<skill-base-dir>/scripts/`.
- Read, create, or update `PRODUCT.md`, `DESIGN.md`, a design sidecar, surface briefs, or critique snapshots.
- Rely on impeccable's detector hook, live mode, pins, or a command other than `impeccable detect`.
- Link to a reference outside `references/`.

Keep the judgment those steps carry: where a lens says to read `DESIGN.md`, read
the project's own design system, tokens, and neighboring screens instead.

## Precedence

- The project's design system, components, and tokens win over every lens.
- Interface copy follows `ux-writing` over `clarify.md`; flows and state
  inventories follow `ux-flows`; CLI output follows `cli-design`.
