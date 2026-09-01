---
name: cross-model-review
description: Host-side orchestration for native cross-model review passes replacing foreign CLI subprocess execution.
---

# Cross-Model Review

This skill defines the host-side orchestration contract for cross-model review passes. It replaces foreign agent CLI invocations with native oh-my-pi (`omp`) seat dispatches.

## 1. When It Fires

A skill procedure asks for another model's judgment and would otherwise invoke a foreign agent CLI (`claude`, `codex`, `grok`, `cursor-agent`). The instruction core forbids that transport, which is why those passes currently report "not run" instead of failing loudly.

Native seat dispatch replaces foreign CLI execution in these concrete cases:
- `ce-doc-review`: Cross-model review pass (formerly `cross-model-doc-review.sh`).
- `ce-code-review`: Cross-model adversarial review pass (formerly `cross-model-adversarial-review.sh`).
- `ce-brainstorm`: Reasoning elevation pass (formerly `elevation-dispatch.sh`).

Write-delegation (`ce-work` implementation engine / `work_engine_mode`) is explicitly NOT covered. Peer review seats hold no tools and cannot author code.

## 2. Self-Attestation

The host determines its own model family before selecting a peer. The host reads its active model identity from prompt context. This value is available because `includeModelInPrompt` is enabled in agent settings.

The host resolves its model string to a family using this identity-to-family resolution table:

| Model Identity Prefix | Model Family |
| --------------------- | ------------ |
| `anthropic/*` | `claude` |
| `google-antigravity/gemini-*` | `gemini` |
### Fail-Closed Rule

If the host model identity does not match any prefix in this table, the host MUST fail closed. The host records the pass state as `not run`. The host MUST NOT guess or infer a model family.

## 3. Candidate Order

A host never dispatches a review to its own family. The host drops its own family from candidate consideration and attempts peers in deterministic priority order:

| Host Family | Primary Candidate | Secondary Failover Candidate |
| ----------- | ----------------- | ---------------------------- |
| `claude` | `gemini` | — |
| `gemini` | `claude` | — |

### Rationale for Candidate Ordering

A `claude` host selects `gemini` and a `gemini` host selects `claude`. This ensures peer review always runs on a distinct model family with an independent training baseline.
## 4. Dispatch

The host dispatches peer reviews in a single `task` batch call.

Batch composition:
- Exactly one item per activated review lens (e.g., adversarial lens, coherence lens, security lens).
- Exactly one whole-document sweep item.

Dispatch item properties:
- `agent`: The candidate seat name (`claude` or `gemini`).
- `schemaMode`: `"permissive"` (avoids hard aborts on minor formatting issues; host validates output explicitly).
- `outputSchema`: The findings return JSON schema defined below.

## 5. Material Transport

Peers hold no tools (`tools: []`). Peers cannot read the filesystem, execute bash commands, write files, or spawn subagents.

Material delivery rules:
- Lens items: The host inlines the exact slice and diff relevant to each lens directly into the dispatch prompt.
- Sweep item: The host inlines the entire document directly into the dispatch prompt.
- File paths: The host NEVER passes a file path or URL for the peer to read.
- Oversized documents: An oversized document that exceeds prompt limits is out of reach for the whole-document sweep rather than read from disk. The concrete sweep payload limit is deferred by the unified plan.

## 6. Collection and Validation

The host collects peer returns and validates each return against the findings schema before synthesis.

Validation failure handling:
- If a return fails schema validation, the host records the attempt state as `unparseable`.
- The parent review continues immediately.
- The cross-model pass is non-blocking: peer validation failure never aborts or blocks the parent review.

## 7. Independence Verification

The host verifies model independence by inspecting the `model_identity` field in the peer return. The peer copies this string directly from its own prompt context.

Independence rules:
- Matching family: If the peer's resolved `model_identity` family matches the host's family, the host records the pass as non-independent. Peer findings still fold into synthesis, but no multi-model agreement promotion applies.
- Missing identity: If `model_identity` is absent or empty, the host records the pass as non-independent. No agreement promotion applies.
- Declared alias warning: A declared `model:` alias indicates only what model was requested, not what model actually served the request. The echoed `model_identity` proves true runtime independence.
- Reporting: A non-independent pass MUST say so in Coverage. Findings that fold in without independence are single-family findings, and a Coverage line that reports only a finding count reads as cross-model verification that never happened.

## 8. Failover

If the primary candidate fails, times out, or produces an unusable return (`unparseable` or infrastructure error), the host invokes failover.

Failover rules:
- The host dispatches the secondary candidate family from the candidate order table exactly once.
- The host never loops or attempts a third dispatch.
- The host records both the primary attempt and the secondary attempt in review output and Coverage.

## 9. Fold-In and Apply Authority

Validated peer findings enter the parent review's ordinary deduplication and synthesis pipeline.

Apply authority rules:
- Peer findings NEVER carry apply authority.
- Peer findings are NEVER treated as safe to auto-apply.
- A peer-only finding is NEVER silently applied without parent agent validation.

## 10. Coverage Vocabulary

Every cross-model review attempt MUST report three things: its target family, exactly one terminal state from this closed seven-state set, and whether the attempt was independent.

Independence is reported alongside the state, never folded into it — a peer can return findings and still be non-independent, so the two are separate facts. Write it as `independent` or `non-independent (<reason>)`, where the reason is `same family` or `identity absent`. An attempt that never reached a peer is neither: omit the independence clause for `not run` and `no different family available`.

Each state has exactly one mutually exclusive trigger:

| State | Trigger |
| ----- | ------- |
| `not run` | Host active model identity is unattested or unmapped in the resolution table, or the pass was skipped prior to candidate dispatch. |
| `no different family available` | All candidate families differing from the host family are unconfigured, disabled, or unreachable. |
| `failed` | Candidate dispatch returned an explicit tool error, authentication failure, network failure, or process error before producing output. |
| `timed out` | Candidate dispatch exceeded its execution deadline without returning a response payload. |
| `unparseable` | Candidate dispatch returned a response payload, but the payload failed validation against the findings schema. |
| `no additional issues` | Candidate return validated successfully against the schema and contained zero findings (`findings` array is empty). |
| `<N> findings` | Candidate return validated successfully against the schema and contained N findings (`findings` array length N > 0). |

## Findings Return Schema

Every peer dispatch must provide an `outputSchema` enforcing this JSON schema:

```json
{
  "type": "object",
  "properties": {
    "reviewer": {
      "type": "string",
      "description": "The lens name the host asked the peer to apply."
    },
    "model_identity": {
      "type": "string",
      "description": "The peer's own resolved model identity copied verbatim from prompt context."
    },
    "findings": {
      "type": "array",
      "items": {
        "type": "object",
        "properties": {
          "title": {
            "type": "string",
            "description": "A concise title summarizing the finding."
          },
          "severity": {
            "type": "string",
            "enum": ["P0", "P1", "P2", "P3"],
            "description": "Severity rating of the finding."
          },
          "section": {
            "type": "string",
            "description": "The relevant section, heading, or line reference in the reviewed material."
          },
          "why_it_matters": {
            "type": "string",
            "description": "Explanation of the impact or risk of this issue."
          },
          "finding_type": {
            "type": "string",
            "enum": ["error", "omission"],
            "description": "Classification of the finding."
          },
          "suggested_fix": {
            "type": "string",
            "description": "Concrete recommendation to resolve the issue."
          },
          "confidence": {
            "type": "integer",
            "enum": [50, 75, 100],
            "description": "Confidence score percentage for this finding."
          },
          "evidence": {
            "type": "array",
            "items": {
              "type": "string"
            },
            "minItems": 1,
            "description": "Non-empty list of verbatim quotes from the reviewed material."
          }
        },
        "required": [
          "title",
          "severity",
          "section",
          "why_it_matters",
          "finding_type",
          "suggested_fix",
          "confidence",
          "evidence"
        ],
        "additionalProperties": false
      }
    },
    "residual_risks": {
      "type": "array",
      "items": {
        "type": "string"
      },
      "description": "List of residual risks identified by the reviewer."
    }
  },
  "required": [
    "reviewer",
    "model_identity",
    "findings",
    "residual_risks"
  ],
  "additionalProperties": false
}
```
