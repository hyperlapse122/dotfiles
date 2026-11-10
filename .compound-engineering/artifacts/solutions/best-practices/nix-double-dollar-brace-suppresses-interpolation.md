---
title: "`$${...}` in Nix is a full escape, not a literal `$` plus interpolation"
date: 2026-09-23
category: best-practices
module: "NixOS modules (Wi-Fi env-var substitution, modules/nixos/wifi.nix)"
problem_type: best_practice
component: tooling
severity: medium
applies_when:
  - "Building a string that needs a literal `$` immediately followed by an interpolated Nix value, such as a shell/env-var reference like `$HOME_SSID` for envsubst- or EnvironmentFile-style substitution"
  - "Porting a mental model from another templating language (shell's `\$var`, Jinja's `{{ ... }}` escaping) onto Nix's `${...}` syntax"
  - "A generated config file contains the literal text `${...}` instead of an interpolated value, and the build itself gave no error"
root_cause: logic_error
resolution_type: code_fix
related_components:
  - testing_framework
tags:
  - nix
  - string-interpolation
  - escape-sequence
  - networkmanager
  - ensureprofiles
  - sops-nix
---

# `$${...}` in Nix is a full escape, not a literal `$` plus interpolation

## Context

`modules/nixos/wifi.nix` (declarative Wi-Fi provisioning, issue #69) needed each `networking.networkmanager.ensureProfiles.profiles.<label>.wifi.ssid` value to hold a literal `$` immediately followed by an uppercased, interpolated label and a literal `_SSID` suffix — e.g. `$HOME_SSID` — because that string is not the SSID itself, it is a placeholder NetworkManager's `environmentFiles`/`envsubst` mechanism substitutes at activation time from the rendered `sops.templates."wifi.env"` dotenv file.

The first attempt wrote this the way a shell or Jinja habit suggests: `wifi.ssid = "$${lib.toUpper label}_SSID";`, reading `$$` as "an escaped, literal first `$`" followed by an ordinary `${...}` interpolation. That reading is wrong, and the build gave no signal that it was wrong — `nix build` and `nix flake check` both succeeded. The bug only surfaced because `tests/wifi-provisioning.nix`'s VM check asserts on the *rendered* `.nmconnection` file content (`ssid=TestHomeNet` etc.), and that assertion failed.

## Guidance

**`$${` in a Nix string (either `"..."` or `''...''`) is itself a complete escape sequence.** It does not mean "literal `$`, then start interpolating." It suppresses interpolation for that whole `${...}` block and passes the text through completely unevaluated and unchanged, including the extra `$`, the braces, and everything between them. There is no partial reading where the first `$` is literal and the second `$` still opens interpolation.

Confirmed directly, isolating the value from any other string context (writing each variant to its own file via `builtins.toFile` and `cat`-ing it, so no outer interpolation could confound the result):

```nix
let
  label = "home";
  variantDoubleQuoted = "$${pkgs.lib.toUpper label}_SSID";
  variantIndented      = ''$${pkgs.lib.toUpper label}_SSID'';
  variantConcat        = "$" + pkgs.lib.toUpper label + "_SSID";
in ...
```

```text
doubleQuoted=[$${pkgs.lib.toUpper label}_SSID]
indented=[$${pkgs.lib.toUpper label}_SSID]
concat=[$HOME_SSID]
```

Both the plain double-quoted string and the indented string come back byte-for-byte identical to the source text — `pkgs.lib.toUpper label` is never evaluated as an expression at all, it stays as inert characters. Only the plain string-concatenation form (`"$" + expr + "_suffix"`) produces the intended `$HOME_SSID`.

**The fix is plain string concatenation**, not any interpolation-syntax variant: write the literal `$` as its own string and concatenate the interpolated piece next to it, as `modules/nixos/wifi.nix:90` and `:93` now do:

```nix
wifi.ssid = "$" + lib.toUpper label + "_SSID";
wifi-security.psk = "$" + lib.toUpper label + "_PSK";
```

## Why This Matters

This is silent at every layer that would normally catch it. `nix build`, `nix flake check`, and `nix fmt` all treat `$${...}` as perfectly valid syntax — it is valid syntax, just not the syntax the author intended — so the module evaluates, the derivation builds, and the host would activate a `.nmconnection` profile whose `ssid=` line reads literally `${lib.toUpper label}_SSID` instead of the real network name. Only a check that inspects the *rendered output* (this repo's `tests/wifi-provisioning.nix` VM test asserting on the keyfile content) or the *runtime behavior* (NetworkManager failing to associate with a network literally named `${lib.toUpper label}_SSID`) surfaces it. A reviewer reading the source without running anything would plausibly wave the line through, since `$${...}` visually looks like a deliberate, careful escape.

## When to Apply

- Any Nix code that assembles a string meant to be consumed by something *else's* placeholder syntax (`envsubst`, systemd `EnvironmentFile=`, a template engine, a shell script the derivation writes) where that consumer's own placeholder also starts with `$`.
- Whenever the intended output has a literal `$` character sitting directly next to an interpolated Nix value, in either `"..."` or `''...''` strings.

## Examples

Before (silently wrong — evaluates cleanly, produces literal `${...}` in the output):

```nix
wifi.ssid = "$${lib.toUpper label}_SSID";
```

After (correct — produces `$HOME_SSID` for `label = "home"`):

```nix
wifi.ssid = "$" + lib.toUpper label + "_SSID";
```

If the surrounding text is itself multi-line and better suited to an indented string, the same rule holds — concatenate around the interpolation rather than trying to escape into it:

```nix
''
  ${"$" + lib.toUpper label}_SSID=${config.sops.placeholder."wifi/${label}/ssid"}
''
```

## Related

- `modules/nixos/wifi.nix` — `wifi.ssid`/`wifi-security.psk` (lines 90, 93 at the time of writing) and `sops.templates."wifi.env".content`, which needed the same literal-`$`-then-interpolated-value shape for the dotenv keys NetworkManager's `environmentFiles` substitutes.
- `tests/wifi-provisioning.nix` — the two-node `nixosTest` whose keyfile-content assertions are what actually caught this; a check that only built the derivation or ran `nix flake check` would not have.
