---
title: "Go text/template's missingkey=error misses index lookups and printed nulls"
date: 2026-10-19
last_updated: 2026-10-19
category: logic-errors
module: "packages/text-template (renderer of the shared agent instructions)"
problem_type: logic_error
component: tooling
severity: medium
symptoms:
  - "{{ if index .user \"missing\" }}...{{ end }} renders the false branch and exits 0 under Option(\"missingkey=error\")"
  - "A key present with a JSON null prints <no value>, or <nil> through print and printf, with no error"
  - "Removing Option(\"missingkey=error\") leaves a test that only prints a missing key green, because the output scan catches the printed <no value> instead"
root_cause: logic_error
resolution_type: code_fix
framework_version: "go 1.26.8"
related_components:
  - testing_framework
tags:
  - go-text-template
  - missingkey
  - fail-open
  - mutation-testing
  - agent-instructions
  - nullable-values
---

# Go text/template's missingkey=error misses index lookups and printed nulls

## Problem

The shared agent instructions are rendered from a Go `text/template` (`home/h82/agents/instructions/instructions.md.tmpl`) by `packages/text-template`, which must fail the build when the template reads a fact the host facts lack. `Option("missingkey=error")` looks like it gives that guarantee, but it covers only one of the ways a template reads data. A rule gated on a missing fact can vanish from every delivered file while every check stays green.

## Symptoms

- `{{ if index .user "missing" }}BAD{{ end }}` executes with `err == nil` and empty output under `missingkey=error` (reproduced with nixpkgs Go 1.26.8 in this session). The builtin `index` returns the zero value for a missing map key and never consults the option.
- A key that is present with a JSON `null` is not "missing". `{{ .desktopSSH.publicKey }}` prints `<no value>`, and `{{ printf "%v" .desktopSSH.publicKey }}` prints `<nil>`, both without an error. Every host without a desktop SSH key carries `desktopSSH.publicKey = null`.
- In a mutation run that removed `Option("missingkey=error")`, a fixture that only *printed* the missing key stayed green: Go's default prints `<no value>`, and the renderer's output scan caught that instead.

## What Didn't Work

- **Relying on `missingkey=error` alone.** It errors only on a field lookup (`.user.missing`) against a map, and only when the action is evaluated.
- **A missing-key test that prints the key.** It cannot tell whether `missingkey=error` is set, because the output scan for printed nulls fails the same render either way. The mutation survived until a fixture read the missing key inside an `if` (`tests/text-template/missing-read.tmpl`), where Go's default renders nothing for the scan to see.
- **Scanning the output for `<no value>` and `<nil>`.** The first renderer did this. It fails the build when the prose itself contains either literal, and it misses a null that a function transformed before printing: `{{ printf "%x" .null }}` hex-encodes Go's `<nil>`, and `{{ printf "%d" .null }}` prints `0`.
- **Tests that used only field access.** The first renderer check covered `.user.missing` printed and read in an `if`, and both passed. The `index` gap surfaced only in the cross-model adversarial code review before the pull request opened, not in the check.

## Solution

Four guards in `packages/text-template/main.go`, the first a precondition of the others, together covering every path:

1. Decode the data into `map[string]any`, not structs (`main.go:64-73`). The Go documentation scopes `missingkey` to indexing a map with a key that is not present, so the option has no effect on struct data.
2. Set `Option("missingkey=error")` and replace the builtin `index` with a strict version through the FuncMap (`main.go:75-77`). `strictIndex` (`main.go:176`) fails on a missing map key with the same `map has no entry for key` wording a field lookup uses:

   A FuncMap entry named like a builtin overrides it, so the template still calls `index`, and the renderer defines no new functions.
3. Replace each JSON null with a nil pointer to a sentinel type (`main.go:31`, `convert` at `main.go:107`). A nil pointer is false in an `if`, as the null was. Its `String` method returns a random nonce generated per run, so an action that prints it, directly or inside a printed map, writes the nonce, and the renderer fails when the output contains it (`main.go:98`). Prose can contain `<no value>` and `<nil>` freely.
4. Wrap the formatting builtins `print`, `printf`, `println`, `html`, `js`, and `urlquery` so a null argument, or a map or list holding one, fails (`rejectNull` at `main.go:135`). These are the paths where a function could transform the nonce before it reaches the output, as `printf "%x"` does.

The check `tests/text-template.nix` pins each path with its own fixture: a printed missing key, a missing key read in an `if`, a missing key passed to `index` inside an `if` (`missing-index.tmpl`), a printed null, a null inside a printed map, a null passed to each wrapped builtin and then hex-encoded by `printf "%x"` so only the wrapper can catch it, and a range over a null. The happy-path fixture also takes a condition on a `null` value (`{{ if .desktopSSH.publicKey }}`), which must render its false branch without failing.

## Why This Works

Go's `text/template` reads data through several paths, and `missingkey` governs only one of them:

| Template read | Missing key | Present `null` |
| --- | --- | --- |
| `.a.b` printed | error under `missingkey=error` | prints `<no value>` |
| `.a.b` in `if` | error under `missingkey=error` | false branch, no error |
| `index .a "b"` | zero value, no error (builtin) | zero value, no error |
| `print`/`printf` of the value | as its argument | prints `<nil>` |

The strict `index` closes the third row, the sentinel and its output check close the printed-null cells, and the wrapped builtins close the cells where a function would transform the null first. A condition on a present `null` stays allowed on purpose: that is how a section can be gated on an optional fact.

## Prevention

- When a renderer promises to fail closed, list every path the template language reads data through and give each one a failing fixture. A single "missing key" fixture tests one path.
- Make the missing-key fixture read the key inside an `if`, not only print it, so it fails when `missingkey=error` is removed and an output scan would otherwise mask the mutation. Mutation-test the option, the strict `index`, the output check, and each wrapped builtin; every one of those mutations was killed on this branch.
- `missingkey=error` and the strict `index` error only when the action is evaluated. A missing key inside a branch that is false on one host passes there and fails on another, so build every host before trusting a template change.
- See also [mutation testing for check assertions](../best-practices/mutation-testing-reveals-decorative-nix-check-assertions.md) and [nullable options that reach a shell comparison as an empty word](../best-practices/nullable-option-empty-operand-passes-a-shell-comparison.md), the same fail-open shape in shell.
