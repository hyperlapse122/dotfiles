---
name: ux-flows
description: "Designing or reviewing how a person moves through something they operate: user flows, navigation and information architecture, and the state inventory of each step (empty, loading, partial, error, success, recovery), for screens, CLIs, prompts, and notifications. Use while brainstorming, planning, building, or reviewing such work."
---

# UX Flows

Design the path before the screen. A flow that ignores the person's actual task
cannot be rescued by layout or copy.

## 1. Start from the task

- Name who arrives, what they are trying to finish, and what tells them they
  are done. Write it as their task, not as the feature.
- Find the shortest path to that outcome. Every extra step, choice, setting, or
  confirmation must earn its place by preventing a real mistake or answering a
  real need; otherwise remove it.
- Default to the common case. Put rare options behind the common path, not in
  front of it.

## 2. Map the flow

For each step, write one line: what the person sees, what they can do, and
where each action leads. Then check:

- **Entry points:** every way someone arrives (link, notification, deep link,
  command, retry), and whether each one has the context it needs.
- **Exits:** finishing, cancelling, going back, and leaving midway. Leaving
  midway keeps their work, or tells them before it is lost.
- **Dead ends:** no step without a next action.
- **Irreversible actions:** confirm only these, at the moment of the action,
  naming what will happen. Prefer undo over confirmation when undo is possible.

## 3. Structure what they see

- Group by the person's task and vocabulary, not by the data model or the
  team that owns the code.
- Keep navigation shallow and predictable: the same thing lives in one place
  and has one name everywhere.
- Show what matters for the current step first; move the rest to progressive
  disclosure.

## 4. Inventory the states of every step

For each step that loads, saves, or depends on data, decide what the person
sees in each state before building it:

| State | Decide |
| --- | --- |
| Empty | Why it is empty, and the one action that fills it |
| Loading | What stays usable; never show the empty state while the first load is still running |
| Partial | What shows when some data is missing, long, or still arriving |
| Error | What failed, whether their input is kept, and how to retry or recover |
| Success | How they know it worked, and where they go next |
| Offline or slow | What still works, and what waits |
| No permission | What they can do instead, and who can grant access |

A state with no decision is a bug waiting to ship.

## 5. Command-line and prompt flows

The same rules apply to a CLI, an interactive prompt, or a notification:

- Every interactive prompt has a non-interactive equivalent (flag or
  environment variable) and a safe default; scripts must never hang on a
  prompt.
- Confirm only destructive actions, and offer a flag to skip the confirmation
  in automation.
- Report the outcome: what changed, where, and what to run next. Exit with a
  non-zero status on failure.
- A notification names the event and the action it invites; it never asks for
  attention it cannot justify.

## Hand-offs

- Wording of labels, errors, empty states, and onboarding: `ux-writing`.
- Visual treatment of states and screens: `design-lenses`.
- CLI flags, help, and output conventions: `cli-design`.
- The project's existing patterns and design system win over this skill.
