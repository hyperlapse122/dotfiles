---
title: A chezmoi Template Guard Built from hasKey Plus an Empty-String Test Accepts null
date: 2026-09-17
category: integration-issues
module: chezmoi
problem_type: logic_error
component: development_workflow
symptoms:
  - "a render-time guard written to reject a missing required field passes a field declared as null"
  - "the guard's own fixtures all pass because every fixture omits the key rather than nulling it"
  - "a managed config file receives a null or empty value where the guard was supposed to stop the render"
root_cause: missing_validation
resolution_type: code_fix
severity: medium
tags:
  - chezmoi
  - execute-template
  - go-template
  - sprig
  - validation
  - yaml
---

# A chezmoi Template Guard Built from hasKey Plus an Empty-String Test Accepts null

## Problem

`.chezmoitemplates/agent-roster-validate.tmpl` is the render-time gate that every consumer of `agents.roster` calls before reading it. Its required-field check was written as the obvious idiom:

```gotemplate
{{- if or (not (hasKey $leadEntry "model")) (eq $leadEntry.model "") -}}
{{-   fail (printf "agent-roster-validate: lead.%s is missing model" $leadAgent) -}}
{{- end -}}
```

That predicate does not reject `model: null`. The key exists, so `hasKey` is true; the value is nil, and comparing nil to `""` is false. Both arms of the `or` are false and the gate passes a field with no usable value.

## Symptoms

- A lead entry declared as `effort: null` renders successfully and prints the full worker list, where a failure naming the entry was expected.
- Every fixture written alongside the guard passes, because each one omits the key entirely.
- With the field present-but-invalid, the value flows through to whatever the consumer does with it — in this case `"model_reasoning_effort": null` in the object written to `~/.codex/config.toml`.

## What Didn't Work

Nothing was tried and rejected; the gap survived because of how the guard was tested, not because of a failed fix.

The guard shipped with five negative fixtures, and all five exercised an **absent** key: no `model`, no `effort`, no `codex` entry, an unknown agent, a lead map missing a required agent. Absence is the case the author is thinking about while writing `hasKey`, so absence is the case the fixtures cover. `null` is the same field in a different invalid state, and no fixture reached it. The guard was green, and green against its own blind spot.

The gap was found by an independent adversarial review that constructed the null case directly rather than reading the predicate and agreeing with it.

## Solution

Add an explicit type test to each required-field check, so a value that is present but not a usable string fails:

```gotemplate
{{- if or (not (hasKey $leadEntry "model")) (not (kindIs "string" $leadEntry.model)) (eq $leadEntry.model "") -}}
{{-   fail (printf "agent-roster-validate: lead.%s is missing model" $leadAgent) -}}
{{- end -}}
```

Live at `.chezmoitemplates/agent-roster-validate.tmpl:49` and `:53`. Reproduce the original failure against any guard you suspect:

```sh
chezmoi --config <empty.toml> --source "$PWD" execute-template \
  '{{- $lead := dict "codex" (dict "model" "x" "effort" (fromJson "null")) -}}{{ includeTemplate "agent-roster-validate.tmpl" (dict "roster" (dict "lead" $lead "workers" .agents.roster.workers)) }}'
```

Before the fix this exits 0. After it, it fails with `agent-roster-validate: lead.codex is missing effort`.

## Why This Works

Go templates have three distinct states for a mapping entry — absent, present-and-nil, present-and-typed — and the two common predicates each cover only one boundary. `hasKey` separates absent from present and says nothing about the value. `eq $v ""` separates the empty string from other strings and is false for nil, because nil and `""` are different types. A required-field check needs all three states covered, and `kindIs "string"` is what closes the middle one.

YAML makes this reachable rather than theoretical: `effort:` with nothing after it, `effort: null`, and `effort: ~` all produce a present key with a nil value, and all three are things a person edits a data file into.

## Prevention

**Test the present-but-invalid state, not just the absent one.** When adding a fixture for a required field, add its null sibling in the same commit. The repository's fixtures now cover both (`.ci/test-agent-roster.sh`), and the null fixtures are the ones that fail if the type test is ever simplified away.

**Do not write a required-field guard as a two-arm `or`.** The shape that actually holds is three arms — key present, value typed, value non-empty:

```gotemplate
{{- if or (not (hasKey $e "field")) (not (kindIs "string" $e.field)) (eq $e.field "") -}}
```

**A gate protects only its callers.** The same review found that this validator was invoked by two payload templates and by neither settings script, so the consumer that actually indexed the validated node rendered invalid values straight into a managed config file. Adding the missing `includeTemplate` call (`.chezmoiscripts/70-agents/run_after_config-codex-settings.sh.tmpl:7`) is a separate fix from tightening the predicate — neither substitutes for the other. When adding a render-time gate, grep for every consumer of the data it guards and confirm each one calls it.
