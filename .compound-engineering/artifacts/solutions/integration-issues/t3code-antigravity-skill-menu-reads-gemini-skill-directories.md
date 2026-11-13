---
title: T3 Code builds its Antigravity skill menu from the ~/.gemini skill directories, not from the runtime
date: "2026-11-14"
category: integration-issues
module: T3 Code Antigravity provider instance and the Antigravity skill root
problem_type: integration_issue
component: tooling
severity: medium
symptoms:
  - "A T3 Code Antigravity session's model lists and reads the Compound Engineering plugin skills, but the composer's / menu lists none of them"
  - "The same menu lists the shared and Xcode skills"
  - "The provider instance home holds no skill of its own, only links to ~/.gemini"
root_cause: config_error
resolution_type: config_change
related_components:
  - documentation
retire_when: "A T3 Code release stops scanning ~/.gemini/config/skills and ~/.gemini/antigravity-cli/skills for Antigravity skills, or starts listing skills the ACP runtime reports; check discoverAntigravitySkills in the release's AntigravitySkills driver"
tags: ["antigravity", "t3code", "skills", "skill-root", "plugin-skills", "acp", "gemini-home", "slash-menu"]
---

# T3 Code builds its Antigravity skill menu from the ~/.gemini skill directories, not from the runtime

## Problem

In a T3 Code session on the `antigravity` provider instance, the composer's `/` menu listed the shared and Xcode skills but no Compound Engineering plugin skill.
The session's model could still see and read those plugin skills.

## Symptoms

- Asked for its skills, a signed-in session listed 65, `ce-plan` among them, and read `ce-noslop/SKILL.md` from the store directory that `ANTIGRAVITY_ACP_PLUGIN_SKILLS` names.
- The composer's `/` menu offered `humanizer` and the Xcode skills, and nothing from the plugin.
- The session reported that its runtime had told it of no slash command.

## What Didn't Work

The first plan treated the menu as a list the ACP runtime supplies.
The runtime's `_send_available_commands_update` advertises only its built-in commands, `/logout`, and `/usage`, and T3 Code's Antigravity driver does store advertised commands as the provider's slash commands.
From those two facts the plan added a third overlay to the runtime rebuild: advertise every skill as a command and rewrite a `/<name>` prompt into an instruction to follow that skill.

That would have listed the shared and Xcode skills twice, because T3 Code already lists them by another route, and it would have added runtime code to re-check on every Antigravity release.
The plan also could not explain why the shared skills were visible at all: the wrapper in `packages/antigravity-acp-path.nix` leaves a T3 Code instance home alone, and the paths the runtime's Python side resolves did not reach them.
That unexplained fact was the sign that the menu had a source the plan had not found.

## Solution

Link every pinned plugin skill into the Antigravity skill root, which T3 Code scans.
`home/h82/agents/skills.nix` adds one `home.file` link per plugin skill under `.gemini/antigravity-cli/skills`, and under no other root, from the same enumeration that builds the store directory:

```nix
++ lib.mapAttrsToList (
  name: source: lib.nameValuePair "${antigravityRoot}/${name}" { inherit source; }
) pluginSkills
```

`home/h82/agents/xcode-skills.nix` passes the plugin names to the Xcode release entry with the shared ones, through `my.antigravityRootSkillNames`, so an exported Xcode skill that takes a plugin skill's name does not block `checkLinkTargets`.
The runtime rebuild, its overlays, and the wrapper did not change.
The fix is on the branch `fix/antigravity-ce-skill`, unmerged as of this writing.

## Why This Works

T3 Code 0.1.9 reads Antigravity skills from files, in its `AntigravitySkills` driver.

- `discoverAntigravitySkills` scans `~/.gemini/config/skills`, the workspace's `.gemini/skills`, `~/.gemini/antigravity-cli/skills`, and the workspace's `.agents/skills` and `.agent/skills`, in that order. It keeps the first skill it finds for each name and reads only `name` and `description` from the frontmatter.
- `linkAntigravityUserSkills` links the instance home's `config/skills` and `antigravity-cli/skills` to the same directories under `~/.gemini`. This is how the runtime, whose `GEMINI_HOME` is the instance home, reaches the shared skills.

The plugin skills were in none of those directories.
The runtime received them only as the store directory, and the `agy` CLI gets them from its plugin install, which T3 Code does not scan.

Two skill sources now hold the plugin names in a T3 Code session: the store directory, which `packages/antigravity-acp-overlay/paths_overlay.py` puts first, and the skill root.
Runtime 1.4.5 lists such a skill once and takes it from the first directory.
A signed-in probe showed this with `ce-noslop` linked into the root: one entry, read from the store directory, and an unchanged total of 65.

The store directory stays because Compound Engineering's run homes read skills only from their own `GEMINI_HOME`, and the wrapper links only the shared names there.

## Prevention

- Before designing a change to what a T3 Code provider offers in its composer, read that provider's driver in the installed bundle. Advertised ACP commands and listed skills are separate channels for Antigravity, and only the second one carries skills.
- When a session shows something no path in this repository explains, find the source before planning. Here the visible shared skills pointed at T3 Code's own links.
- A skill handed to a runtime by an environment variable is not in a skill root. Whatever lists skills from the roots will not show it.
- `tests/antigravity-skills.nix` requires every plugin skill to be linked into the Antigravity root with its plugin source as the target, and lists the expected names from the sources on disk. Keep that enumeration independent of `plugin.skills`, or the check compares the function with itself.
- The repository checks prove the links. They do not prove the menu, which needs a signed-in T3 Code session after a production switch.

Not yet observed: whether a signed-in `agy` CLI lists a plugin skill twice now that its plugin install and the skill root both provide it, and whether the menu runs a skill that sets `disable-model-invocation`, which the session's model does not list.

On the macOS host, `agy` CLI 1.5.8 moved `~/.gemini/antigravity-cli/skills` to `~/.gemini/config/skills` on 2026-11-14 and left a symlink, so Home Manager's links now land in `config/skills` through it. T3 Code scans both paths and keeps one entry per name.

## Related Issues

- [The stock Antigravity ACP runtime loads no global rule files](antigravity-acp-runtime-loads-no-global-rule-files.md): why the runtime is rebuilt, and the signed-in probe method used here.
- [T3 Code's ACP agent sessions ignore user-level MCP config](t3-acp-sessions-ignore-user-mcp-config.md): another case where a T3 Code provider session does not read what the agent's own CLI reads.
- The plan for this change: `.compound-engineering/artifacts/plans/2026-11-14-0043-fix-antigravity-skill-slash-commands-plan.md`.
