# mxm4-haptic (Claude Code plugin)

A [Claude Code](https://docs.claude.com/en/docs/claude-code) **plugin** that
pulses the MX Master 4's built-in haptics on Claude Code lifecycle events. When
a turn finishes, the mouse gives a tactile "done" buzz — handy for kicking off a
long agent run and feeling, rather than watching, for completion.

It is the Claude Code counterpart of
[`@h82/opencode-mxm4-haptic`](../../../../packages/opencode-mxm4-haptic/), and
maps the same events to the same waveforms so both agents buzz identically. Where
the OpenCode plugin is a TypeScript module talking to the daemon over a socket,
this one is pure declarative config: a hook manifest that shells out to the
`mxm4-haptic` CLI. No build step, no runtime dependency.

## What it does

| Claude Code hook | Waveform | Meaning |
|---|---|---|
| `Stop` | `COMPLETED` | The agent finished its turn. |
| `StopFailure` | `MAD` | The turn ended on an API error (rate limit, overload, auth, …). |
| `Notification` (`permission_prompt`, `elicitation_dialog`) | `RINGING` | The agent is waiting on **you** to approve something — answer it. |
| `PreToolUse` (`AskUserQuestion`) | `RINGING` | The agent asked you to pick an option — answer it. |

### Sub-agent gating is free here

The OpenCode plugin has to inspect every session's `parentID` and poll child
session status, because `session.idle` fires for **each** sub-agent — buzzing on
all of them would fire repeatedly during one fan-out.

Claude Code needs none of that: `Stop` and `StopFailure` fire for the **root**
agent only. A sub-agent completing fires `SubagentStop`, which this plugin
**deliberately does not hook** — hooking it would reintroduce exactly the
once-per-sub-agent buzzing the OpenCode plugin works to suppress.

### Never interferes with a turn

Every hook runs [`bin/pulse`](bin/pulse), which **always exits 0 and prints
nothing**. That matters: a Claude Code hook exiting non-zero surfaces an error to
the user, and exit 2 *blocks* the event. So a buzz that can't be delivered — the
daemon is stopped, the mouse is asleep, the binary isn't built yet — is a silent
no-op rather than a broken session.

The underlying client is non-blocking (~1 ms, with a 500 ms socket write timeout
as the worst case), and the daemon already debounces (120 ms) and paces (180 ms)
pulses, so even a chatty hook cannot spam the motor.

## Do not edit these files

This directory is **chezmoi source state**, deployed to
`~/.local/share/claude-plugins/mxm4-haptic/`:

- The event→waveform map lives in
  [`.chezmoidata/haptic.yaml`](../../../../.chezmoidata/haptic.yaml) under
  `haptic.claude`. **Tune a waveform there**, then `chezmoi apply`.
- [`hooks/hooks.json`](hooks/hooks.json.tmpl) is *generated* from that data. A
  waveform name that isn't one of the 16 in
  [`crates/mxm4-haptic/src/lib.rs`](../../../../crates/mxm4-haptic/src/lib.rs)
  (`WAVEFORMS`) fails the apply loudly rather than silently never buzzing.

## Prerequisites

The `mxm4-hapticd` user daemon must be running — it owns the AF_UNIX socket at
`$XDG_RUNTIME_DIR/mxm4-haptic.sock` that the CLI writes to:

```sh
systemctl --user status mxm4-hapticd.service
```

If it's down, pulses are silently skipped. Both the daemon and the `mxm4-haptic`
client are built from [`crates/mxm4-haptic/`](../../../../crates/mxm4-haptic/)
into `~/.local/bin/` by `.chezmoiscripts/60-build/`.

Hardware: a Logitech **MX Master 4** paired (HID++ feature `0x19B0`). Linux only —
the daemon owns Linux `hidraw`, so the plugin is not deployed on macOS/Windows.

## Install

**chezmoi does it automatically on Linux.**
`.chezmoiscripts/70-agents/run_onchange_after_install-claude-plugins.sh.tmpl`
registers the deployed tree as a local marketplace and installs the plugin:

```sh
claude plugin marketplace add ~/.local/share/claude-plugins --scope user
claude plugin install mxm4-haptic@dotfiles --scope user
```

A local-directory marketplace is **referenced in place, not copied** — Claude
Code reads the manifest from `~/.local/share/claude-plugins/` live, so a
`chezmoi apply` that re-renders `hooks.json` takes effect on the next session
with no re-install. Both commands are idempotent (a second `install` exits 0 with
"already installed").

Installing writes only `enabledPlugins` and `extraKnownMarketplaces` into
`~/.claude/settings.json`. It does **not** touch that file's `hooks` key, so
hooks written there by other tools (e.g. `aoe`) are unaffected — plugin hooks
are merged with them at load time, not substituted for them.

Verify:

```sh
claude plugin list
claude plugin validate ~/.local/share/claude-plugins/mxm4-haptic --strict
```

## Extending

Add an event to `hooks/hooks.json.tmpl` and its waveform to `haptic.claude` in
`.chezmoidata/haptic.yaml`. The full 16-waveform table (`SHARP COLLISION`,
`HAPPY ALERT`, `MAD`, …) is documented in
[`packages/mxm4-haptic/README.md`](../../../../packages/mxm4-haptic/README.md).

Claude Code exposes ~30 hook events; the ones most worth a buzz beyond the four
above are `Notification` with the `agent_completed` / `agent_needs_input`
matchers (background sessions). Resist hooking `SubagentStop` — see the gating
note above.
