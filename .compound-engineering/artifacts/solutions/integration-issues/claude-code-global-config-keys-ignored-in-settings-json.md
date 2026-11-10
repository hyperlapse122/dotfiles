---
title: Claude Code ignores global-config keys declared in settings.json
date: "2026-09-30"
category: integration-issues
module: Claude Code settings (Home Manager activation)
problem_type: integration_issue
component: activation
severity: medium
symptoms:
  - "A `/config` toggle declared in `settingsTier` of `home/h82/agents/claude.nix` has no effect in Claude Code"
  - "The `claude` check passes, because it compares the rendered declared JSON with its own mirror, not what Claude Code reads"
root_cause: wrong_api
resolution_type: code_fix
tags: ["claude-code", "settings-json", "claude-json", "global-config", "home-manager", "activation", "agent-settings", "t3code", "claude-config-dir", "context", "model-settings", "autocompact"]
last_updated: "2026-10-19"
retire_when: "Claude Code reads the key from settings.json; check a newer binary's strings for the key in the settings schema (`<key>:()=>`) or in the short settings-first key list that holds inputNeededNotifEnabled and agentPushNotifEnabled (`iCe` in 2.1.285, `nbe` in 2.1.296; minified names change per release)"
---

# Claude Code ignores global-config keys declared in settings.json

## Problem

Claude Code keeps its settings in two files. `~/.claude/settings.json` holds settings. `~/.claude.json` holds global config, which is also the tool's runtime state. Some `/config` toggles persist only to the global config file. This repository declares Claude Code settings by merging keys into `settings.json` at activation. A global-config key declared there is written and then never read.

## Symptoms

- The first plan for turning off "← opens agents" put `leftArrowOpensAgents = false` in `settingsTier`. That would have written the key into `settings.json`, and the left arrow would still have opened the agents view.
- Nothing fails. The `claude` check diffs the declared file the module renders against the values the check expects. Both sides hold the key, so the check passes whether or not Claude Code reads it.

## What Didn't Work

- **Inferring the file from a key list.** In the 2.1.285 binary, the key appears in a list (`var a6n=[...]`) next to `preferredNotifChannel`, `inputNeededNotifEnabled`, and `agentPushNotifEnabled`. This repository already declares those three in `settings.json`, and they work. That list is the full set of global-config keys, though, and it does not say which file each key is read from. The plan used it as evidence and was wrong. Doc review of the plan (the feasibility and adversarial reviewers) caught it before implementation.

## Solution

Find the code that reads the key. Do not rely on where the key is listed. In Claude Code 2.1.285:

- The gesture, the footer hint, and the tip all read `ce().leftArrowOpensAgents !== false`. `ce()` is the global-config reader, which reads `~/.claude.json`.
- The `/config` toggle writes the key through the global-config setter.
- The settings schema has no `leftArrowOpensAgents` entry.
- A second list, `var iCe=[...]`, names the global-config keys that are read from the user settings file first and fall back to global config. The three notification keys above are in it, which is why they work from `settings.json`. `leftArrowOpensAgents` is not in it.

The fix declares such keys in their own tier. A second activation entry runs the same `agent-settings` merger against `~/.claude.json`. See `globalConfigTier` and `home.activation.claudeGlobalConfig` in `home/h82/agents/claude.nix`. `tests/claude.nix` runs the same assertions (activation present, target file, declared JSON) for both merges.

`advisorModel` works from `settings.json`. The repository first declared it in the same change and has since retired it (`retiredKeys` in `home/h82/agents/claude.nix`). The settings schema has an entry for it: `advisorModel:()=>...describe("Advisor model for the server-side advisor tool.")`.

To check a key, extract strings from the unwrapped binary (`bin/.claude-wrapped` in the `claude-code` store path) and search them with Python `re`. In this environment `grep` is `ugrep`, which rejects the long-line patterns this needs.

```sh
strings -n 6 "$(dirname "$(readlink -f "$(command -v claude)")")/.claude-wrapped" > strings.txt
python3 - <<'EOF'
import re
s = open('strings.txt', encoding='latin1').read()
key = 'leftArrowOpensAgents'
for pat in [rf'ce\(\)\.{key}', rf'{key}:\(\)=>']:
    for m in list(re.finditer(pat, s))[:2]:
        print(pat, '->', s[max(0, m.start()-80):m.end()+120].replace('\n', ' '))
# The two key lists are minified under names that change per release
# (2.1.285: a6n and iCe; 2.1.296: NEr and nbe), so find them by content.
# The long one also holds installMethod; the short one is the settings-first list.
for name, body in re.findall(r'var ([\w$]+)=(\[[^\]]*"agentPushNotifEnabled"[^\]]*\])', s):
    kind = 'all global-config keys' if '"installMethod"' in body else 'settings first'
    print(name, kind, key in body)
EOF
```

On 2.1.296 this prints two `ce().leftArrowOpensAgents` readers, no schema entry, `NEr all global-config keys True`, and `nbe settings first False`.

If a key has a `ce().<key>` reader and is in neither the settings schema nor the settings-first list, it belongs in `~/.claude.json`.

### Measure the effect with /context when Claude Code reports it

When the key's effect shows in what `claude -p` prints, such as the auto-compact window in `/context`, measure it instead of reading strings. Copy the config directory, edit only the copy, and run `/context` with the flags a T3 Code session uses:

```sh
T=$(mktemp -d)
cp -r ~/.claude/. "$T"/
cp ~/.claude.json "$T"/.claude.json
jq '.autoCompactWindow=400000' ~/.claude/settings.json > "$T/settings.json"
cd /tmp && CLAUDE_CONFIG_DIR="$T" claude -p /context --model claude-opus-5-5 \
  --settings '{"fastMode":false,"showThinkingSummaries":true}' | grep -E 'Tokens:|Autocompact'
rm -rf "$T"
```

The copy keeps the login, and the real `~/.claude/settings.json` is never touched. On Claude Code 2.1.296 this printed `**Tokens:** 16.2k / 400k (4%)` and `| Autocompact buffer | 33k | 8.3% |`; without the key, `16.2k / 1m`. Precedence tests the same way: adding `modelSettings: {"claude-opus-5-5": {"autoCompactWindow": 300000}}` beside the top-level key printed `16.2k / 300k`, so the per-model value that `/autocompact` writes outranks the top-level key. The `agent-settings` merger assigns only declared keys and leaves `modelSettings` alone, so an `/autocompact` choice survives rebuilds. The repository declared the top-level key as `400000` from 2026-10-12 and has since retired it (`retiredKeys` in `home/h82/agents/claude.nix`), so sessions now use the model's full window.

### T3 Code sessions read the user settings file

To see what a T3 Code session loads, read its arguments with `tr '\0' '\n' < /proc/<pid>/cmdline`. On T3 Code 0.0.46 nightly (the `t3code-desktop-0.0.46-nightly.20261011.2980` store path) with Agent SDK 0.3.276 (the session's `CLAUDE_AGENT_SDK_VERSION`), sessions run `/etc/profiles/per-user/h82/bin/claude` with `--model claude-opus-5-5` and `--settings '{"fastMode":false,"showThinkingSummaries":true}'`, and with no `--setting-sources`. Without `--setting-sources` the CLI loads the user settings file, so a `settingsTier` key reaches T3 sessions as it does terminal sessions. The `--settings` value is a higher-precedence flag layer, so a key it carried would win over the user file. It carries only those two keys. A T3 session observed on 2026-10-12 also answered in the language the user file's `language` key sets, which is consistent with this.

## Why This Works

Each file has its own reader, and a key takes effect only where its reader looks. For the keys in the settings-first list (`iCe` in 2.1.285), the reader checks settings first and then falls back to global config. That is how older global-config keys became settable from `settings.json`. Keys added outside that list, such as the agent-view toggles, have only the global-config reader.

## Prevention

- Before adding a key to `settingsTier`, confirm the binary reads it from settings: it is in the settings schema, or it is in the settings-first list. Otherwise add it to `globalConfigTier`.
- Treat a passing `claude` check as proof of what activation writes, not of what Claude Code reads. When the key's effect shows in `/context` or another `claude -p` output, measure it against a copied config directory as above.
- After a T3 Code or Agent SDK bump, re-read a T3 session's arguments. A `--setting-sources` flag, or a `--settings` value that carries a declared key, would change what those sessions read. [Checks that read an option value instead of the materialized output](../best-practices/nix-check-reads-option-value-not-materialized-output.md) covers the same kind of gap.
- Merging into `~/.claude.json` carries risks that the `settings.json` merge does not:
  - When the file is absent, the merger creates it holding only the declared keys. Claude Code then does not print its hint about restoring a backup of a missing global config.
  - The merger does not take Claude Code's config lock. A running session can write its cached copy over the merged key, and the key stays missing until the next rebuild that produces a new generation.
  - The merger sets the file's parent directory to `0700`. That parent is `$HOME`, which is already `0700` here.
