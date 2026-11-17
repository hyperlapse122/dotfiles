---
title: Antigravity Video Delegation - Plan
type: feat
date: 2026-11-17
topic: antigravity-video-delegation
artifact_contract: ce-unified-plan/v1
product_contract_source: ce-brainstorm
execution: code
---

# Antigravity Video Delegation - Plan

## Goal Capsule

- **Objective:** Agents in T3 Code sessions can understand a local video's content by delegating it to an Antigravity model shown to read native video, and the instructions claim video support only for models that passed.
- **Means:** Trials of Gemini Carbon, Argon, and Hydrogen through T3 `delegate_task` children (KTD1), followed by a T3-only instruction section built from the results (KTD4).
- **Product authority:** Issue #196 and the scope the owner confirmed in this conversation, recorded in the Product Contract below. The Product Contract wins on behavior; KTDs win on mechanism.
- **Open blockers:** None. The owner switched this Mac to a generation that includes #195; `allowNonWorkspaceAccess` is present in `~/.gemini/antigravity-acp/settings.json` and `~/.gemini/antigravity-cli/settings.json`.
- **Stop conditions:** Stop and report if the trial children cannot start on the `antigravity` provider, or if a trial is rejected because the file lies outside the workspace. That rejection means the #195 setting is not in effect; it is an environment fault, not a model limitation recorded under R5.
- **Execution:** One PR that closes #196. U1 runs on this Mac in T3 before U2 edits anything; host activation stays owner-run.

---

## Product Contract

### Summary

Run three native-video trials per Antigravity model on one recorded video and record each model's outcome.
If any model passes, add T3-only instructions that send video understanding to the best-performing passing model, with the other passing models as fallbacks.
If none passes, record the blockers and add no video instructions.

### Problem Frame

T3 orchestrators such as Claude and Codex cannot view a local video file directly.
The first trials with `~/Downloads/live-draft.mp4` stopped at the outside-workspace file check before any model received video content, so they say nothing about native video support.
PR #195 removed that file-access barrier, but no instruction tells an agent which Antigravity model, if any, can analyze video.

### Key Decisions

- **Delegate whenever video content is needed.** Governs R7. (session-settled: user-approved — chosen over delegating only on explicit user request or always delegating: an agent that needs a video's content and cannot view it should hand it off without being told.)
- **Rank by trial quality with fallbacks.** Governs R8. (session-settled: user-approved — chosen over following the CE model ladder or listing passing models without a choice: the trial evidence, not role tiers, decides which model reads video best.)
- **No frame-extraction fallback.** Governs R9, R10. (session-settled: user-approved — chosen over instructing a frame-extraction fallback: the instructions cover only verified native video, and a failure is reported to the user.)
- **Three runs per model on one video.** Governs R1. (session-settled: user-approved — chosen over one run per model or several videos: one success shows support, three runs give a ranking, and repository evidence warns against ranking models on one sample.)
- **Hydrogen breaks ties.** Governs R8. The CE ladder already sends every Antigravity child to Hydrogen, so a tie keeps delegation on the model agents already use.

### Requirements

**Trials**

- R1. Each of Gemini Carbon, Argon, and Hydrogen receives `~/Downloads/live-draft.mp4` three times through the managed Antigravity ACP runtime that T3 Code uses.
- R2. A run counts as native video input only when the session transcript shows the model received the video file itself and ran no tool that extracted frames or converted the video.
- R3. A run passes when its scene descriptions and timestamps match reference frames that the tester extracts independently from the same video.
- R4. Each run's record names the model, the input path, whether input was native or frame-based, the pass or fail verdict, and the scene or timestamp evidence behind it.
- R5. A run that fails before the model sees content records the transport or model limitation, such as a size, format, or access error.
- R6. The trial results appear in the PR description and in a comment on issue #196.

**Instructions**

- R7. When at least one model passes, the shared instruction template's T3 branch tells an agent that needs a local video's content, and cannot view video itself, to delegate the analysis to a verified model.
- R8. The instructions name the model with the best trial results as the first choice and the other passing models as fallbacks, with Hydrogen first on a tie.
- R9. The instructions give only input guidance that the trials demonstrated, such as how the video path is passed.
- R10. When no model passes, the instructions gain no video-support claim and the recorded blockers are the outcome.
- R11. `docs/agent-routing.md` and the instruction receipt hashes in `tests/agent-instructions.py` match the changed template, and the instruction checks pass.

### Acceptance Examples

- AE1. **Covers R2.** Given a Hydrogen run whose transcript shows a shell call to `ffmpeg` before the answer, when the run is recorded, then it counts as frame-based and does not count toward native support.
- AE2. **Covers R7, R8.** Given Carbon passing three runs, Hydrogen passing two, and Argon failing all three, when a Claude orchestrator in T3 needs the content of a screen recording, then it delegates to Carbon and falls back to Hydrogen; Argon is not named.
- AE3. **Covers R7.** Given Carbon passed, when the T3 orchestrator is itself a Carbon session, then it reads the video directly instead of delegating.
- AE4. **Covers R10.** Given every run fails at input, when the PR is written, then the template has no video instructions and the PR and issue comment list each model's blocker.

### Scope Boundaries

- A frame-extraction fallback for agents or models that cannot read native video.
- A second test video or a broader benchmark of video understanding.
- Video support claims in the non-T3 user instructions or for harnesses other than the T3 Antigravity provider.
- Running host activation; the owner keeps that step.

### Dependencies / Assumptions

- The switched generation that includes #195 stays active during the trials.
- The trials run in T3 sessions, which use the same managed ACP runtime and settings as delegated Antigravity children.

### Outstanding Questions

**Deferred to Implementation**

- Whether the results warrant a learning under `.compound-engineering/artifacts/solutions/`, judged by the repository's `ce-compound` rule once the trials finish.

### Sources / Research

- Issue #196 and PR #195 (`allowNonWorkspaceAccess` for Antigravity CLI and ACP).
- `.compound-engineering/artifacts/plans/2026-11-17-0040-feat-antigravity-non-workspace-access-plan.md`
- `home/h82/agents/instructions/instructions.md.tmpl` (T3 branch at the top) and `docs/agent-routing.md` (T3 delegation section and Antigravity ladder evidence).
- `.compound-engineering/artifacts/solutions/best-practices/benchmark-cross-model-review-peers-in-t3-code-before-changing-them.md`
- `.compound-engineering/artifacts/solutions/integration-issues/antigravity-acp-runtime-loads-no-global-rule-files.md` (why T3 Antigravity children see the rebuilt runtime's rules, not the stock one's).
- Product Contract preservation: unchanged except that planning resolved the input-path question (KTD1) and moved the learning question to implementation.

---

## Planning Contract

### Key Technical Decisions

- KTD1. **Trials run as T3 `delegate_task` children that read the video by absolute path.** Covers R1, R2. Each child runs on provider `antigravity` with model `gemini-4-carbon`, `gemini-4-argon`, or `gemini-4-hydrogen` and receives `/Users/hyperlapse/Downloads/live-draft.mp4` in its brief, then opens it with its own file-viewing tool. This is the same route a future video delegation takes, and #195's plan records that this tool returns media once the outside-workspace check passes. The brief tells the child not to use shell tools; the child's thread transcript, read with `t3_thread_read`, decides R2 either way.
- KTD2. **The orchestrator builds the reference independently.** Covers R3. Before reading any child result, extract still frames from the 4.04-second, 854x480 video at a fixed interval (every 0.5 s is enough) with `ffmpeg`, view them, and write down what each interval shows. Child answers are scored against that record, never against each other.
- KTD3. **Every trial child and every delegated video child runs at `thinking_level` `high`, passed explicitly in `target.options`.** Covers R1, R8, R9. Carbon and Argon list no `xhigh`, so one shared level keeps the comparison fair. T3's default is not reliable for this: `docs/agent-routing.md` records that T3 once listed `xhigh` as Hydrogen's default. The instruction section therefore names `high` so delegated children run at the level the trials measured.
- KTD4. **A new `# T3 video analysis` section in the template's T3 branch, mirrored by `## T3 video analysis` in `docs/agent-routing.md`.** Covers R7 through R11. It sits after `# T3 visual options`. The routing doc also gets a `### Video trial evidence` subsection with the per-run table, following the pattern of `### Gemini selection evidence`.
- KTD5. **Fixed scoring, set before any child result is read.** Covers R3, R8. The reference has eight half-second intervals. A run scores one point per interval it describes correctly and loses one per claim the reference contradicts. A run passes when it scores at least 6 and makes no contradicted claim about the overall scene sequence. A model passes when at least one of its three runs passes, per the settled three-run decision. Models rank by the sum of their three scores; ties go to Hydrogen per the Product Contract Key Decision.

### Assumptions

- A 4-second video gives only coarse timestamp evidence; a pass means the model described the scene sequence correctly at half-second resolution.
- `delegate_task` children are the managed ACP runtime T3 Code uses, so their results stand for T3 sessions in general.
- Posting the trial results as an issue comment is covered by this autonomous run, since `.compound-engineering/config.yaml` approves writes to `hyperlapse122/dotfiles` issues.

---

## Implementation Units

### U1. Run and record the native video trials

- **Goal:** Produce a per-run record for all nine trials (three models, three runs each) and a verdict per model.
- **Requirements:** R1, R2, R3, R4, R5; KTD1, KTD2, KTD3, KTD5.
- **Dependencies:** None.
- **Files:** None in the repository. Keep the reference record and the raw child answers in the session scratchpad; U2 and the PR carry the results.
- **Approach:**
  1. Build the reference record per KTD2.
  2. Start the nine children per KTD1 with one shared brief: open the file, describe what happens in each half-second, report the duration it observed, and state how it received the file.
  3. For each finished child, read its thread and classify the run as native, frame-based, or failed before content (R2, R5).
  4. Score native runs per KTD5 and pick the first choice and fallbacks.
- **Execution note:** Each child is a cross-provider `delegate_task`; follow T3's task lifecycle for waits, and do not count a child's own summary as proof of what tools it ran.
- **Test expectation:** none -- this unit is a measurement; its proof is the recorded transcripts and scores.
- **Verification:** Nine rows exist, each with model, input path, input kind, verdict, and evidence; every native pass names at least one interval that matches the reference.

### U2. Add the T3 video analysis instructions

- **Goal:** Ship the instruction section and its documentation when at least one model passed; otherwise ship no instruction change.
- **Requirements:** R6, R7, R8, R9, R10, R11; AE1 through AE4; KTD4.
- **Dependencies:** U1.
- **Files:** `home/h82/agents/instructions/instructions.md.tmpl`, `docs/agent-routing.md`, `tests/agent-instructions.py`.
- **Approach:**
  1. If no model passed, skip the steps below; R10 and AE4 govern, and the results go only to the PR and issue (R6).
  2. Write the template section: when to delegate (R7), which model first and which as fallbacks (R8), how to pass the video and the `thinking_level` to use (R9, KTD3), and that a passing orchestrator reads the video itself (AE3).
  3. Mirror it in `docs/agent-routing.md` and add the evidence table (KTD4).
  4. Update the `t3` receipt in `EXPECTED`; the other receipts stay unchanged because the edit sits inside the `.t3` branch.
- **Patterns to follow:** `# T3 visual options` in the template and its mirror in `docs/agent-routing.md`; the evidence-table style under `### Gemini selection evidence`.
- **Test scenarios:**
  - Covers AE2. The T3 render contains the new section with the U1 first-choice model named first and a model that failed every run absent.
  - The `nixos` and `darwin` baseline renders keep their existing receipts, so no video text leaks outside the T3 branch.
  - Changing one word of the new section makes the `t3` receipt fail (the existing mutation loop in `check_receipt` covers this).
- **Verification:** The `agent-instructions` check passes on this Mac with the new `t3` receipt.

---

## Verification Contract

| Gate | Command or evidence | Applies to |
| --- | --- | --- |
| Trial evidence | Nine recorded runs with transcripts read through `t3_thread_read` | U1 |
| Instruction receipts | `nix build --no-link .#checks.aarch64-darwin.agent-instructions` | U2 |
| Markdown | `markdownlint-cli2` on changed Markdown | U2, plan |
| Whitespace | `git diff --check` | all |
| Formatting and full CI | `nix fmt -- --ci` runs in CI's `fmt` job (no Darwin formatter); `full-ci` label with `host-checks`, `vm-checks`, `build`, and `build-darwin` green on the head | PR |

---

## Definition of Done

- Every model has three recorded runs and a verdict, and the PR body and an issue #196 comment carry them (R4, R5, R6).
- When a model passed, the T3 branch carries the video section, `docs/agent-routing.md` mirrors it with the evidence table, and the `agent-instructions` check passes (R7 through R11).
- When no model passed, the template is unchanged and the blockers are recorded (R10).
- No scratch trial files, extracted frames, or abandoned edits remain in the repository diff.
