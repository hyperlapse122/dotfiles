---
title: Feedback Sweep - Plan
date: 2026-09-07
topic: feedback-sweep
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-sweep
execution: code
---

# Feedback Sweep - Plan

## Goal Capsule

**Objective.** An operator applying this repo to a host gets tools that are what upstream published and commands that actually run: every external whose lock entry carries a digest is verified against it before it is trusted, every declared command name resolves to a real binary, and a tool version moving does not leave a stale binary behind. A platform this repo declares fails in CI rather than at apply time on a host, and a CI gate cannot go unwired silently. The agent-config boundary denies what it means to deny, and no root is silently exempted.

**Means:** harden the lock-to-host path at each of the five seams it currently trusts by convention — digest verification, tag pinning, render-time platform coverage, lock-addressed store identity, and link resolution (KTD1, KTD3, KTD4, KTD5).

**Authority hierarchy.** This plan's Product Contract (R22-R32) is preserved from the ce-sweep ledger and outranks the Planning Contract. A preserved requirement may leave this plan's scope on exactly two grounds, both recorded in Scope Boundaries with evidence rather than silently reinterpreted: research invalidated its premise (R22), or a confirmed blocker sits outside this repository (R32). R24 is the one exception and is called out as such — it leaves scope on a cost-and-approach judgment recorded as a Key Technical Decision (KTD2), with its premise intact. A KTD may not otherwise outrank a preserved requirement.

**Stop conditions.** Stop and report rather than improvising when: a CI gate added here cannot be wired into `.github/workflows/ci.yml` (`.ci/test-ci-wiring.sh` fails the run); the SELinux type split cannot satisfy `.ci/test-selinux-protected-configs.sh`'s compiled-policy matrix; or the store-identity change (U9) would strand a running process that `packages/command-reconcile/src/prune.ts` cannot prove idle.

---

## Human Notes

<!-- human-notes:start -->
<!-- Everything between these markers is human-owned. The reconciler never reads or writes inside this region. Add your own context, priorities, and decisions here. -->
<!-- human-notes:end -->

---

## Product Contract

**Product Contract preservation:** unchanged. R22-R32 keep the meaning and IDs the ce-sweep ledger assigned. Three requirements (R22, R24, R32) are moved out of this plan's active units and recorded under Scope Boundaries with the evidence that deferred them; none was rewritten or reinterpreted.

### Summary

Eight of the eleven swept items are implementation-ready here and are covered by U1-U9. They share one spine: the path from `.chezmoidata/releases.json` through the chezmoi externals into the versioned command store trusts convention at five seams — no digest on twenty lock-URL-backed externals, no tag pin on bun, two declared platforms that no CI leg ever renders, a store identity that ignores content, and a public link that is never resolved. Two items sit outside that spine: the `.ci/lib` hygiene pair and the SELinux plugins-root type split. Three items are deferred with evidence: R22's proposed mechanism does not exist in the shipped Ghostty, R24 is a larger refactor this plan explicitly declines in favor of R23, and R32 turns on product decisions this run cannot make.

### Problem Frame

`.chezmoidata/releases.json` is the declared authority for every pinned tool, and `.chezmoitemplates/release-lock-ref.tmpl` already exposes `url`, `sha256`, `sha512` and `size` per platform. The consumers do not use most of it. Twenty lock-URL-backed stanzas — thirteen in `.chezmoiexternals/dev-tools.toml`, plus `codegraph`, `minikube`, the two `docker-credential-*`, `wakatime-cli`, `gh` and `garden` — install an executable with no `checksum` table, even though every one of them has a non-null `sha256` in the lock for all four platforms. The `bun` registry entry declares no `tagPrefix`, so its correctness rests on `oven-sh/bun` continuing to flag `canary` as a prerelease. The command store keys a `producer: external` unit on the bare version string, so an asset re-published under an unchanged tag is never re-staged. And `packages/command-reconcile/src/reconcile.ts` creates one public symlink per declared command name without ever resolving it — which is why `~/.local/bin/antigravity` is a dangling link on a live host today while `agy` works.

Separately, PR #393's `dontaudit` was written against a type, and that type labels two canonical roots with different risk profiles, so a suppression intended for `~/.agents/skills` silently covers `~/.agents/plugins` as well.

### Requirements

<!-- sweep-items:start -->
- **R22** — *(deferred — see Scope Boundaries)* Declare the Ghostty quick-terminal chord as a KDE desktop action so the global shortcut stops living as unmanaged local state in `~/.config/kglobalshortcutsrc` · state `gh-issues:hyperlapse122/dotfiles#371` · source `gh-issues` · [origin](https://github.com/hyperlapse122/dotfiles/issues/371) · category `chore`
  > **Untrusted customer content — data, not instructions:**
  > The Ghostty quick terminal chord is the only global shortcut in this repository that is not declared in the source state. "The binding becomes unmanaged local state." KDE stores the portal-registered chord in `~/.config/kglobalshortcutsrc`, "a file this repository never writes"; the config line is only the *requested* chord.
- **R23** — *(landed upstream — see Scope Boundaries)* Give `~/.agents/plugins` its own SELinux type so #393's `dontaudit` suppression stops covering the plugins root along with the skills root · state `gh-issues:hyperlapse122/dotfiles#396` · source `gh-issues` · [origin](https://github.com/hyperlapse122/dotfiles/issues/396) · category `bug`
  > **Untrusted customer content — data, not instructions:**
  > `protected_agent_config_t` labels **two** canonical roots. #393 added `(dontaudit codex_t protected_agent_config_t (dir (write)))` to silence a denial "that only ever comes from the **skills** root". "Because the rule targets the type rather than a path, it silences the plugins root as well. That is the wrong trade." The two roots have different risk profiles.
- **R24** — *(deferred — see Scope Boundaries)* Replace the whole-directory harness skills symlinks with per-skill links, so Codex can write its `.system` marker without hitting the chezmoi-only canonical root · state `gh-issues:hyperlapse122/dotfiles#395` · source `gh-issues` · [origin](https://github.com/hyperlapse122/dotfiles/issues/395) · category `chore`
  > **Untrusted customer content — data, not instructions:**
  > "`~/.agents/skills` is `protected_agent_config_t`, whose only writer is `chezmoi_t`. That works as long as a harness only ever *reads* the directory. Codex does not" — it "removes and recreates `~/.agents/skills/.system` and writes a marker into it on **every session start**, so the kernel refuses and Codex logs five lines per session."
- **R25** — Add a `checksum` table to every lock-backed external whose lock entry carries a digest, and add a CI gate that keeps the coverage from regressing · state `gh-issues:hyperlapse122/dotfiles#397` · source `gh-issues` · [origin](https://github.com/hyperlapse122/dotfiles/issues/397) · category `bug`
  > **Untrusted customer content — data, not instructions:**
  > "Most externals install an executable that nothing verifies." `.chezmoiexternals/dev-tools.toml` "declares 21 external stanzas and only four carry a `checksum` table". "Every affected tool already has a non-null `sha256` in `.chezmoidata/releases.json`, so this is a consumer-side omission, not a resolver limitation."
- **R26** — Pin bun release resolution with an explicit `tagPrefix` so the lock cannot follow the rolling `canary` train · state `gh-issues:hyperlapse122/dotfiles#398` · source `gh-issues` · [origin](https://github.com/hyperlapse122/dotfiles/issues/398) · category `bug`
  > **Untrusted customer content — data, not instructions:**
  > "The `bun` registry entry declares no `tagPrefix`, so `resolveGitHubRelease` reads `releases/latest`. Correctness then depends on `oven-sh/bun` keeping its rolling `canary` release flagged prerelease or draft. If that ever slips, the lock silently follows the canary train and the asset selector still matches every name, so nothing downstream would notice."
- **R27** — Make the locked bun version part of the reconciler build fingerprints and the `vp run build` cache key, so a lock-driven bun bump actually rebuilds · state `gh-issues:hyperlapse122/dotfiles#399` · source `gh-issues` · [origin](https://github.com/hyperlapse122/dotfiles/issues/399) · category `bug`
  > **Untrusted customer content — data, not instructions:**
  > "A lock-driven bun bump does not rebuild anything." "The staged `command-reconcile` and `settings-reconcile` binaries stay compiled by the previous bun until some tracked source file happens to change."
- **R28** — Add render coverage for the musl-Linux and darwin-amd64 external renders, so asset-name/archive-path drift fails in CI rather than at apply time on a real host · state `gh-issues:hyperlapse122/dotfiles#400` · source `gh-issues` · [origin](https://github.com/hyperlapse122/dotfiles/issues/400) · category `chore`
  > **Untrusted customer content — data, not instructions:**
  > "Two platform combinations are declared but never exercised, so a drift between an asset name and the archive path derived from it would surface as an apply-time extraction failure on a real host rather than in CI." The `-musl` branch "is only ever checked by the expected-name table in `packages/release-lock/test/registry.test.ts`. That table proves the selector; it does not prove the selector and the template agree."
- **R29** — Fix `.ci/lib`'s committed modes, bring `.ci/lib/` into the wiring check, and harden the bun ladder's first rung against a relative `command -v` result · state `gh-issues:hyperlapse122/dotfiles#401` · source `gh-issues` · [origin](https://github.com/hyperlapse122/dotfiles/issues/401) · category `bug`
  > **Untrusted customer content — data, not instructions:**
  > `.ci/lib/bun.sh` "is committed `0755` with a shebang, but its header says it is source-only", and the orphan check matches only `.ci/test-*.sh` and `.ci/check-*.sh`, "so a future gate placed under `.ci/lib/` would be unwired silently." Rung 1 "uses `command -v bun`, whose output is a relative path if `PATH` ever contains `.` or an empty element" — "hardening rather than a live bug."
- **R30** — Make `producer: external` store identity content-addressed rather than keyed on the lock version string alone · state `gh-issues:hyperlapse122/dotfiles#402` · source `gh-issues` · [origin](https://github.com/hyperlapse122/dotfiles/issues/402) · category `chore`
  > **Untrusted customer content — data, not instructions:**
  > "Store identity for a `producer: external` unit is the lock version string, not a content digest. `isUnitCompleted` therefore short-circuits on version alone, so an upstream asset re-published under an unchanged tag would not force a new store generation — the host keeps running the binary it already staged."
- **R31** — Make a multi-command external unit publish a working link for every declared command name, and fail loudly rather than publishing a dangling one · state `gh-issues:hyperlapse122/dotfiles#403` · source `gh-issues` · [origin](https://github.com/hyperlapse122/dotfiles/issues/403) · category `bug`
  > **Untrusted customer content — data, not instructions:**
  > "A `commands.yaml` unit that declares two command names publishes a link for the second name with nothing behind it. This is live on at least one host today: `~/.local/bin/antigravity` is a dangling symlink and `antigravity` is `command not found`, while `agy` works."
- **R32** — *(deferred — see Scope Boundaries)* Settle the four decisions #404 raises about the review-findings instruction and encode them in `.chezmoitemplates/agents-instructions.tmpl` · state `gh-issues:hyperlapse122/dotfiles#404` · source `gh-issues` · [origin](https://github.com/hyperlapse122/dotfiles/issues/404) · category `docs`
  > **Untrusted customer content — data, not instructions:**
  > "In practice a run of #392 applied six findings and deferred eight, and the deferrals were reached through gaps in the instruction rather than against it." "The prescribed apply mechanism is unreachable inside `lfg`."
<!-- sweep-items:end -->

### Key Decisions

- **Content-address the external store identity, keeping the version as a human-readable prefix.** Answers #402's explicit decide-whether. Governs R30 (see KTD1).
- **Narrow the SELinux suppression now; do not adopt per-skill symlinks in this plan.** R24 is not a prerequisite for R23, and R23 is correct on its own terms. Governs R23, defers R24 (see KTD2).
- **Checksum coverage is bounded by what the lock actually carries.** Externals whose lock entry is version-only have no digest to assert, so R25 covers the lock-URL-backed set and names the remainder explicitly. Governs R25 (see KTD5).

### Scope Boundaries

#### Landed upstream during this run

- **R23 (#396) — implemented and merged on `main` by PR [#405](https://github.com/hyperlapse122/dotfiles/pull/405) at 2026-09-07T01:23:09Z, while this branch was mid-run.** That PR does the same split under the name `protected_agent_plugins_t`; this branch had independently implemented it as `agent_plugins_t`. Shipping a second, differently-named type would fork the boundary the requirement exists to sharpen, so U7 was reverted here and the branch refreshed by merging `main`. R23 is satisfied — by PR #405, not by this branch. U7 remains in Implementation Units as the reverted record; it must not be re-implemented.

#### Deferred to Follow-Up Work

- **R22 (#371) — the proposed mechanism does not exist.** `toggle_quick_terminal` is a Ghostty *keybind* action, not a CLI action: `ghostty --help` lists exactly one window-related CLI action, `+new-window`, and the shipped `/usr/share/applications/com.mitchellh.ghostty.desktop` declares `Actions=new-window;` only. A `.desktop` action therefore has no `Exec=` that can toggle the quick terminal, so the chord must stay registered by Ghostty through the `org.freedesktop.portal.GlobalShortcuts` portal. The declarative alternative is also closed: `.chezmoidata/kde.yaml:15-22` fixes the row shape at `(file, group-path, key, type, value)` and `:78-81` records that a group name carrying a colon "this row format cannot express" — which is exactly the shape of a `kglobalshortcutsrc` entry. Independently confirmed at the D-Bus layer: the running instance exports `org.gtk.Actions`, but `org.gtk.Actions.List` returns only `open-config, present-surface, quit, new-window-command, new-window, reload-config` — no quick-terminal action. The issue's underlying complaint (unmanaged local state) stands; its proposed remedy does not. **Disposition:** #371 stays open as accepted unowned live surface, annotated with its two re-open triggers — an upstream Ghostty CLI or D-Bus entry point for `toggle_quick_terminal`, or a non-`kde.yaml` mechanism for `kglobalshortcutsrc`. It is not closed as won't-fix; the surface remains unowned and counts against the repo's own unowned-live-surface metric.
- **R24 (#395) — deferred by KTD2**, not by cost alone. See KTD2 for the decision and its rationale.
- **R32 (#404) — blocking product decisions this run cannot make.** #404 asks that four decisions be *settled* and then encoded in `.chezmoitemplates/agents-instructions.tmpl`. Only the first was assessed in depth this run, and it blocks the encoding half for all of them, because the template text depends on how it resolves:
  1. **The unreachable apply mechanism — blocked, out of repo.** `lfg` step 4 mandates `ce-code-review mode:agent`, while `ce-code-review` treats `apply:local` with `mode:agent` as a conflicting-arguments stop. Resolving it means changing one of those two skill definitions, which live in the read-only plugin cache at `~/.local/share/compound-engineering/`, outside this repository's ownership.
  2-4. **Not assessed this run.** The remaining three decisions #404 raises were not analyzed and are not known to depend on the fork above; they are unattempted, not proven blocked. A follow-up should classify each on its own before assuming the whole item is blocked.

#### Out of scope for this plan

- Externals whose lock entry is version-only and carries no artifact digest: `kubectl`, `kubectl-convert`, `helm` (`.chezmoiexternals/k8s.toml`), `glab` (`vcs.toml`), and the `winbox` trio (`system.toml`). Adding digest verification for these requires the release-lock resolver to start recording artifacts for them — a separate change.
- **The joint residual these two exclusions create.** `kubectl`, `kubectl-convert`, `helm` and `glab` are lock-backed `producer: external` command units that receive **neither** fetch-time digest verification (R25) **nor** a digest-bearing store identity (R30). Both defects #397 and #402 describe stay live on exactly these units, and they remain as exposed after this plan as before it. This is stated here because each half is otherwise disclosed only in its own section, and their intersection is the part that matters.
- `.chezmoiexternals/fonts.toml` (URLs come from `.chezmoidata/fonts.yaml`, entirely outside the release lock) and the agent-skill / marketplace GitHub tarballs in `ai-agents.toml` (no lock artifacts exist).
- The `packages/package.json` `packageManager: bun@1.4.0` pin, which is currently out of step with the lock's `bun-v1.4.1`. Recorded under Outstanding Questions; reconciling the two authorities is its own change.

### Outstanding Questions

- **Deferred (non-blocking), U9 rollout.** Changing external store identity re-keys all 30 `producer: external` units on the next apply. Research confirms this is cheap and safe — `producer.ts:132-145` copies from the chezmoi-managed staging path that is already populated, so nothing re-downloads, and `prune.ts:77-176` quarantines then deletes the superseded version-named directories once no running process root references them. The open part is only whether to land U9 in the same apply as the rest; the plan sequences it last so it can be split into its own commit if the operator prefers.
- **Deferred (non-blocking), duplicate bun-version authority.** `packages/package.json` pins `packageManager: bun@1.4.0` while `.chezmoidata/releases.json` locks `bun-v1.4.1`. Two authorities for one fact, currently disagreeing — a duplicate-knowledge defect by the repo's own metric. U6 makes the lock version drive the reconciler builds but does not reconcile this pin, which is a separate change with its own blast radius (it affects the workspace toolchain, not the staged binaries).
- **Deferred (non-blocking), U4 cache input.** Whether `vp`'s task `input` can reference `.chezmoidata/releases.json`, which sits outside the `packages/` workspace root, is an execution-time unknown. The fingerprint half of R27 does not depend on the answer; U4 records the fallback.

### Sources / Research

- State file: `docs/feedback-sweep/state.yml` — 49 items: 38 closed, 11 open.
- Lock authority and its accessor: `.chezmoidata/releases.json`, `.chezmoitemplates/release-lock-ref.tmpl` (fields `version|url|sha256|sha512|size|emulated`; `optional:true` at `:70-79` is what makes a digest-less fallback expressible).
- Failure chain for R31: `.chezmoiexternals/ai-agents.toml:31-36` stages one file `agy` → `.chezmoitemplates/command-manifest.tmpl:31` sets the staging path to the unit directory → `packages/command-reconcile/src/producer.ts:144-145` takes the directory branch and **ignores `unit.commands`** → `packages/command-reconcile/src/reconcile.ts:40-42` links both names, resolving neither.
- `relPath` already flows end-to-end and is validated: `.chezmoitemplates/command-manifest.tmpl:66` → `packages/command-reconcile/src/manifest.ts:90-99` (rejects absolute, `..`, backslash) → `reconcile.ts:42`, `producer.ts:148`, `prune.ts:116,153`.
- Musl probe, duplicated verbatim: `.chezmoiexternals/dev-tools.toml:13-18` and `.chezmoiexternals/ai-agents.toml:6-11`. It shells out to `ldd /bin/ls`, so `--override-data` cannot reach it.
- SELinux module `system/linux/selinux/dotfiles_protected_agent_configs.cil` — types at `:77-88`, the #393 suppression at `:294` with rationale `:255-293`, filecons at `:337-378` (`:339` skills, `:340` plugins). Its gate `.ci/test-selinux-protected-configs.sh` pins the suppression at `:69`, `:194`, `SANCTIONED_DONTAUDIT` at `:660`, mutation tests at `:691-739`.
- Institutional learning: `docs/solutions/security-issues/selinux-user-scope-agent-config-protection.md` (last updated 2026-09-07) — records why these types deliberately carry no base attribute, and that only `chezmoi_t` holds `relabelfrom` on them.
- `values` plumbing for fingerprints is already proven in-tree by `.chezmoiscripts/60-build/run_onchange_after_build-settings-reconcile.sh.tmpl:16-18`; contract at `.chezmoitemplates/fingerprint.tmpl:58-80`.

---

## Planning Contract

### Key Technical Decisions

**KTD1 — External store identity becomes `<version>-<digest12>`, with a sha512 then bare-version fallback.** *Governs R30.* Strictly this is **lock-addressed**, not content-addressed: the suffix comes from the digest the lock records for the resolved platform, not from hashing the staged bytes. That is the right control for the threat #402 names — a lock refresh moves the digest while the version holds — and `packages/release-lock/src/cli.ts:59-61` resolves fresh and merges with no skip-if-version-unchanged path, so a re-published asset does update the recorded digest. U5 supplies the byte-level check at fetch time. The digest is available at render time, so the change lands in `.chezmoitemplates/command-manifest.tmpl` and needs no TypeScript. Keeping the version as a readable prefix preserves the legibility of `~/.local/lib/commands/store/<unit>/<identity>/` for a human debugging a host. Resolution order is `sha256`, then `sha512`, then the bare version: `.chezmoidata/releases.json` records `sha256: null` and a populated `sha512` for all four `agy` artifacts, and `.chezmoiexternals/ai-agents.toml:38-39` already verifies that unit through `[agy.checksum] sha512`, so a sha256-only rule would leave `agy` — the same unit U8 repairs — on a version-only identity. `.ci/check-release-lock-digests.sh` already states that either digest satisfies it. *Prerequisite:* `optional:true` does not currently cover a lock entry with no `artifacts` block, so U9 extends the accessor first — see U9 step 1. *Rejected:* a bare content digest — it makes every store directory opaque and discards the version a human needs when diagnosing. *Rejected:* leaving identity version-only and relying solely on the external `checksum` table (R25) — the checksum forces a re-fetch into staging, but `isUnitCompleted` keeps the store on the old identity, so the two controls genuinely act at different moments. *Rejected:* a bare content digest — it makes every store directory opaque and discards the version a human needs when diagnosing. *Rejected:* leaving identity version-only and relying solely on the external `checksum` table (R25) — that control fires at fetch time and, per #402, is absent for exactly the units that need it most; the two controls cover different moments and are not substitutes.

**KTD2 — Give `~/.agents/plugins` its own type; decline the per-skill symlink refactor.** *Governs R23; defers R24.* The plan's own sequencing note asked whether R24 supersedes R23. It does not. The plugins root deserves its own type on its own merits — it holds the personal marketplace manifest and has a different writer and risk profile from the skills root — and that stays true no matter how skills are linked. R24 is a materially larger refactor whose cost is not justified here: chezmoi cannot emit N sources from one file, so per-skill links mean roughly thirty hand-synced `symlink_<name>` sources across three harnesses, or a reconciler script plus the ordering and pruning that comes with it. Two arguments that look available are **not** load-bearing and are deliberately not relied on. The repo's "declare it as data, never as a script" rule does not forbid a script — it requires scripts be dumb reconcilers over declared data, and the repo ships 73 of them including `.chezmoiscripts/00-tools/run_after_90-activate-command-links.sh.tmpl`, a link reconciler of exactly this shape. And the live skills root is *not* undeclared: per `AGENTS.md`, it is the union of `agents.skills.external` in `.chezmoidata/agents.yaml` and locally-authored `dot_agents/skills/<name>/`, so a per-skill link set is derivable from source state; `.chezmoiremove:22-29` prunes skills *removed* from the manifest, not persistent undeclared content. The decline rests on cost alone, and on R23 being correct independently. *Consequence:* the `dontaudit` at `:294` remains, correctly narrowed to the skills root only, and Codex's failing `.system` marker write under `~/.agents/skills` survives this plan with its audit signal still suppressed.

**KTD3 — Extract the musl probe into a shared partial with a render-time override.** *Governs R28.* The probe is duplicated verbatim in two externals files and shells out to `ldd`, which is why `--override-data` cannot reach it and no CI leg has ever rendered the `-musl` branch. Extracting it to `.chezmoitemplates/musl-probe.tmpl` and having it honor an explicit override before probing gives CI a seam without adding a musl runner. *Rejected:* adding an Alpine CI leg — far heavier, and it would prove the probe rather than the template agreement that actually drifts. *Rejected:* leaving the duplication and overriding in one file only — the two copies would diverge, which is the defect one level up.

**KTD4 — Fix R31 at the data layer, then add a structural guard.** *Governs R31.* `relPath` already flows end-to-end and `reconcile.ts:42` already uses `cmd.relPath ?? cmd.name` for the link target, so declaring `relPath: agy` on the `antigravity` command makes both public links resolve with no code change. That alone would leave the class of bug open, so the guard is the second half: the reconciler must verify a declared command resolves to a real file and return a conflict-shaped failure instead of publishing a dangling link. *Rejected:* making `producer.ts`'s directory branch fan the single staged file out to every declared name — that guesses which file a name means and would silently do the wrong thing for a genuine multi-binary archive.

**KTD5 — Bound R25 by what the lock carries.** *Governs R25.* Twenty lock-URL-backed stanzas have a non-null `sha256` for all four platforms and get a `checksum` table: the thirteen in `dev-tools.toml`, plus `codegraph` (`ai-agents.toml`), `minikube` (`k8s.toml`), the two `docker-credential-*` and `wakatime-cli` (`system.toml`), and `gh` and `garden` (`vcs.toml`). The version-only entries have no digest to assert and are named in Scope Boundaries instead of being silently skipped. The new gate asserts coverage over the lock-URL-backed set specifically, so it fails on a *new* uncovered external rather than demanding the impossible from the version-only ones.

**KTD6 — Carry the bun version into the fingerprint via `values`, not a new glob.** *Governs R27.* `.chezmoidata/releases.json` holds every tool, so globbing it would rebuild both reconcilers whenever any unrelated tool moved. `fingerprint.tmpl` already accepts `values` as `{name, value}` string dicts and the settings-reconcile script already uses it, so passing just the resolved bun version is both narrower and an established pattern.

### High-Level Technical Design

The five seams this plan hardens, along the lock-to-host path:

```mermaid
flowchart LR
  LOCK[".chezmoidata/releases.json<br/>version + per-platform sha256"]
  REG["release-lock registry<br/>packages/release-lock"]
  EXT[".chezmoiexternals/*.toml<br/>chezmoi fetch"]
  STAGE["staging<br/>incomplete/&lt;unit&gt;/"]
  STORE["store<br/>commands/store/&lt;unit&gt;/&lt;identity&gt;/"]
  BIN["public links<br/>~/.local/bin/&lt;name&gt;"]

  REG -->|resolve| LOCK
  LOCK --> EXT --> STAGE --> STORE --> BIN

  S1["U1 · R26<br/>tagPrefix pin"] -.-> REG
  S2["U5 · R25<br/>checksum tables + gate"] -.-> EXT
  S3["U3/U4 · R28<br/>musl + darwin render cover"] -.-> EXT
  S4["U9 · R30<br/>content-addressed identity"] -.-> STORE
  S5["U8 · R31<br/>relPath + resolve guard"] -.-> BIN
```

Each dotted edge is a seam that today trusts convention: an unpinned tag, an unverified download, an unrendered platform, a version-only identity, and an unresolved link.

### Assumptions

- The `agy` archive member `antigravity` and the staged file `agy` are the same binary under two names, so pointing both public links at the one staged file is correct. Evidence: `.chezmoiexternals/ai-agents.toml:31-36` extracts archive member `antigravity` to target file `agy`. U8's guard makes a wrong assumption here fail loudly rather than silently.
- Adding `tagPrefix: "bun-v"` matches the current locked tag (`bun-v1.4.1`), so the pin does not move the locked version.
- `.ci/lib/apt-install.sh` keeps mode `0755` — it is genuinely executed from `.github/workflows/ci.yml:246,275,324`. Only the two sourced-only libraries lose the bit.

### Sequencing

U1, U2 and U6 are independent and can land in any order. U3 precedes U4. **U5 precedes U9** — U9 declares the dependency and it is mechanical, not stylistic. U5 depends on nothing itself but is the largest data edit.

Two units carry their own risk domain and may each be split into an independently mergeable change: **U7** (SELinux policy; its own `secilc`/`python3-setools` toolchain, and the one unit whose failure the Goal Capsule pre-declares as stop-and-report) and **U9** (the store identity re-key). Neither blocks the other seven, which are ordinary TypeScript, CI and chezmoi-data changes.

---

## Implementation Units

### U1. Pin bun release resolution with an explicit tag prefix

**Goal:** the lock cannot follow `oven-sh/bun`'s rolling `canary` release even if upstream stops flagging it prerelease.

**Requirements:** R26.

**Dependencies:** none.

**Files:**
- `packages/release-lock/src/registry.ts` (modify — the `bun` entry)
- `packages/release-lock/test/registry.test.ts` (modify)

**Approach:**
1. Add `tagPrefix: "bun-v"` to the `bun` registry entry, mirroring the existing `codex` (`tagPrefix: "rust-v"`) and `compound-engineering` entries.
2. Verify the prefix matches the currently locked tag so the pin does not move the resolved version.

**Patterns to follow:** the `codex` and `compound-engineering` entries in the same file; `tagPrefix` is declared on the `githubRelease` variant in `packages/release-lock/src/types.ts`.

**Test scenarios:**
- A registry-level assertion that `bun` declares a non-empty `tagPrefix`, so removing it fails the suite.
- Resolution against a stubbed release list containing both a `canary` entry and `bun-v*` tags selects the newest `bun-v*` tag. Mirror the stubbing style in `packages/release-lock/test/github.test.ts:158-217`.
- Resolution against a list whose only entries are `canary` raises the prefix-not-found error rather than falling back.

**Verification:** `vp run -r test` passes in `packages/`, and re-resolving the lock leaves `bun` at its current version.

---

### U2. Harden the bun ladder's first rung and fix .ci/lib modes and wiring scope

**Goal:** `.ci/lib` libraries carry modes that match how they are used, a library placed there cannot go unwired silently, and rung 1 cannot pick up a relative path.

**Requirements:** R29.

**Dependencies:** none.

**Files:**
- `.ci/lib/bun.sh` (mode change + rung 1)
- `.ci/lib/render-gate-helpers.sh` (mode change only)
- `.chezmoitemplates/bun-resolve.sh.tmpl` (mirror rung 1)
- `.ci/test-ci-wiring.sh` (extend)
- `.ci/test-bun-resolve.sh` (extend)

**Approach:**
1. Set `.ci/lib/bun.sh` and `.ci/lib/render-gate-helpers.sh` to mode `0644`. Leave `.ci/lib/apt-install.sh` at `0755` — it is executed directly by the workflow.
2. Harden rung 1 so a `command -v bun` result that is not an absolute path is rejected rather than becoming `BUN_DIR`.
3. Mirror the same rung-1 change in `.chezmoitemplates/bun-resolve.sh.tmpl`. `.ci/test-bun-resolve.sh:31-46` asserts the two declare the same four rungs in the same order, so they must move together.
4. Extend `.ci/test-ci-wiring.sh` to cover `.ci/lib/`: a library that is sourced-only must be non-executable, and anything executable there must be invoked somewhere.

**Execution note:** the wiring check's gate enumeration at `.ci/test-ci-wiring.sh:128-134` is non-recursive by design — extend it with a separate `.ci/lib/` traversal rather than making the existing `glob` recursive, which would sweep libraries into the gate set and demand they be workflow-wired.

**Patterns to follow:** the embedded-Python checker structure already in `.ci/test-ci-wiring.sh:66-179`, including its declared-exception list at `:48-50`.

**Test scenarios:**
- A sourced-only library committed `0755` fails the wiring check; at `0644` it passes.
- `.ci/lib/apt-install.sh` at `0755` still passes, because it is invoked by a workflow.
- Rung 1 with a `PATH` containing an empty element, where `command -v bun` yields a relative path, leaves `BUN_BIN` unset and falls through to rung 2 rather than prepending a relative directory.
- The existing rung-ordering and PATH-prepended-once cases in `.ci/test-bun-resolve.sh:82-142` still pass.

**Verification:** `.ci/test-ci-wiring.sh` and `.ci/test-bun-resolve.sh` both pass; `git ls-files -s .ci/lib` shows `100644` for the two sourced libraries.

---

### U3. Extract the musl probe into a shared partial with a render-time override

**Goal:** one definition of the musl probe, and a seam that lets a render gate select the musl branch without a musl runner.

**Requirements:** R28.

**Dependencies:** none.

**Files:**
- `.chezmoitemplates/musl-probe.tmpl` (create)
- `.chezmoiexternals/dev-tools.toml` (modify — replace the inline probe at `:13-18`)
- `.chezmoiexternals/ai-agents.toml` (modify — replace the duplicate at `:6-11`)

**Approach:**
1. Create the partial. It returns the musl boolean, honoring an explicit override supplied through template data **before** falling back to the `ldd /bin/ls` probe, and probing only when `.chezmoi.os` is `linux`.
2. Replace both inline copies with an `includeTemplate` call, leaving the downstream `$isMuslLinux` / `$bunMuslSuffix` derivations untouched.

**Technical design (directional guidance, not implementation specification):** the override is read from an optional data key; when absent the partial behaves exactly as the current inline probe, so a normal apply on a real host is unchanged.

**Patterns to follow:** `.chezmoitemplates/release-lock-ref.tmpl` for a partial that takes a `dict` context and returns a scalar.

**Test scenarios:**
- Rendering `.chezmoiexternals/dev-tools.toml` on a glibc host with no override produces the same output as before this unit — byte-identical.
- Rendering with the override set true produces `-musl` in both the resolved URL and `$bunArchivePath`.
- Rendering with `.chezmoi.os` set to `darwin` ignores the override and produces no `-musl` suffix.

**Verification:** existing `.ci/test-command-external-render.sh` still passes unchanged, proving the no-override path is a no-op refactor.

---

### U4. Extend the external render gate to musl and darwin-amd64, and assert URL/path agreement

**Goal:** a drift between an asset name and the archive-internal path derived from it fails in CI instead of at apply time on a real host.

**Requirements:** R28.

**Dependencies:** U3.

**Files:**
- `.ci/test-command-external-render.sh` (modify)

**Approach:**
1. Add `darwin:amd64` to the platform list at `:20-24`, and add musl variants for the two Linux architectures using U3's override.
2. Add an assertion stronger than the current shape checks, **scoped to the stanzas whose archive-internal `path` is actually composed from the platform**: `bun`, `bunx`, `wasm-pack`, `uv`, `uvx`, `codex`, `garden`, `minikube`, `wakatime-cli`, `aoe`, `helm`. For those, the platform implied by the resolved `url` and the platform token in `path` must agree. Declare every other stanza an explicit exemption — most `path` values carry no platform token at all (`ast-grep`, `sg`, `buf/bin/buf`, `antigravity`, `bin/gh`, `bin/glab`, `WinBox`), so a blanket assertion would fail on first run.
3. State the token mapping the check uses, because the two vocabularies differ: the URL speaks `<os>-<arch>[-musl]`, while `path` may use a Rust target triple (`x86_64-unknown-linux-musl` for `codex`, `wasm-pack`, `uv`, `garden`) or place the token in the filename rather than the leading directory (`out/minikube-linux-amd64`, `wakatime-cli-linux-amd64`, `aoe-linux-amd64`). A bare suffix comparison does not work.
4. Keep the two existing shape assertions at `:35-41`.

**Execution note:** the gate is already wired into `.github/workflows/ci.yml:209-212`, so no workflow change is needed and `.ci/test-ci-wiring.sh` stays satisfied. Confirm that before assuming it.

**Patterns to follow:** the existing per-platform render loop and `--override-data` usage in the same script.

**Test scenarios:**
- All six combinations render without a template error.
- A deliberately mismatched `path` suffix in a scratch copy of the bun stanza fails the new agreement assertion — prove the gate can fail, not just that it passes.
- Every exempted stanza (`ast-grep`, `bin/gh`, `WinBox`, …) passes without being forced into the platform-token rule.
- A Rust-triple path (`codex`, `uv`) and a filename-token path (`minikube`) each validate under the declared mapping rather than erroring.
- `darwin/amd64` renders a URL with no `-musl` suffix.
- The musl legs render a URL and an archive path that both carry `-musl`.

**Verification:** `.ci/test-command-external-render.sh` passes across six combinations, and the mutation check above fails as designed.

---

### U5. Add checksum tables to every lock-backed external that has a digest

**Goal:** an external that installs an executable verifies it against the digest the lock already records.

**Requirements:** R25.

**Dependencies:** none.

**Files:**
- `.chezmoiexternals/dev-tools.toml` (modify — 13 stanzas)
- `.chezmoiexternals/ai-agents.toml` (modify — `codegraph`)
- `.chezmoiexternals/k8s.toml`, `.chezmoiexternals/system.toml`, `.chezmoiexternals/vcs.toml` (modify — the lock-URL-backed stanzas only)
- `.ci/check-external-checksum-coverage.sh` (create)
- `.github/workflows/ci.yml` (modify — wire the new gate)

**Approach:**
1. Add a `[<name>.checksum]` table with `sha256` to each stanza whose lock entry carries a digest: `ast-grep`, `sg`, the five `buf` artifacts, `marksman`, `shellcheck`, `wasm-pack`, `rust-analyzer`, `uv`, `uvx`, plus `codegraph`, `minikube`, the two `docker-credential-*`, `wakatime-cli`, `gh`, `garden`.
2. Reuse the hoisted-variable form where a stanza already resolves its URL into a variable, and the inline `includeTemplate` form otherwise — both are established in this file.
3. Create the coverage gate. Detection cannot be read off rendered TOML, because the rendered `url` is a bare string with no trace of where it came from. The gate therefore **renders each `.chezmoiexternals/*.toml` per platform and matches each stanza's `url` against the lock's recorded artifact URLs**, requiring a `checksum` table wherever the matched artifact carries a digest. Use the render loop in `.ci/test-command-external-render.sh` for the rendering half and `.ci/check-release-lock-digests.sh` only for the exemption-list style. Key the exemption on *"the matched lock artifact carries no digest"*, not on a hardcoded tool-name list — a name-keyed list would keep exempting a tool after its lock entry later gains a digest.
4. Treat either `sha256` or `sha512` as satisfying the gate, matching the rule `.ci/check-release-lock-digests.sh` already states. `agy` is digest-bearing via `sha512` only, so a sha256-only gate would demand a table it cannot produce.
5. Wire the gate into `.github/workflows/ci.yml` and into the `delivery` job's `needs` if it lands in a new job — `.ci/test-ci-wiring.sh` enforces both.

**Execution note:** this is a wide, mechanical data edit. Prefer render-diff verification — render each externals file before and after and confirm the only additions are `checksum` tables with 64-hex values — over reading all 21 stanzas by eye.

**Patterns to follow:** `[bun.checksum]` at `.chezmoiexternals/dev-tools.toml:196-197` (hoisted variable) and `[android.checksum]` at `:29-30` (inline `includeTemplate`). `.ci/check-release-lock-digests.sh` for a checker that validates shape with a bounded, fully-stated exemption list.

**Test scenarios:**
- Every modified external renders with a 64-hex `sha256` on all four platforms.
- The new gate fails when a `checksum` table is removed from a covered external.
- The new gate passes while the version-only externals still carry no table — the declared exceptions must not be flagged.
- `agy`, whose lock artifacts carry `sha512` and a null `sha256`, is treated as digest-bearing and satisfied by its existing `[agy.checksum] sha512` table.
- The new gate fails when a *new* lock-URL-backed external is added without a table, which is the regression it exists to catch.
- `.ci/test-ci-wiring.sh` passes, proving the gate is wired.

**Verification:** all six render legs from U4 succeed, the new gate passes, and a spot-check confirms one rendered digest matches `.chezmoidata/releases.json`.

---

### U6. Rebuild the reconcilers when the locked bun version changes

**Goal:** a lock-driven bun bump re-runs the onchange build instead of leaving binaries compiled by the previous bun.

**Requirements:** R27.

**Dependencies:** none.

**Files:**
- `.chezmoiscripts/00-tools/run_onchange_after_10-build-command-reconcile.sh.tmpl` (modify)
- `.chezmoiscripts/60-build/run_onchange_after_build-settings-reconcile.sh.tmpl` (modify)
- `packages/command-reconcile/vite.config.ts` (modify)
- `packages/settings-reconcile/vite.config.ts` (modify)

**Approach:**
1. Pass the resolved bun version to `fingerprint.tmpl` as a `values` entry in both build scripts, so the rendered fingerprint changes when the lock moves. The settings-reconcile script already passes a `values` list and only needs a second entry.
2. Attempt to add the bun version to each `vp` task's cache key. If `input` cannot reference a path outside the `packages/` workspace root, fall back to the fingerprint alone and record the limitation in the script header — the onchange fingerprint is the load-bearing half.

**Execution note:** `fingerprint.tmpl:70-79` requires a `values` name matching `^[A-Za-z0-9][A-Za-z0-9._-]*$` and a non-empty **string** value; a non-string fails the render.

**Patterns to follow:** the existing `values` usage in `.chezmoiscripts/60-build/run_onchange_after_build-settings-reconcile.sh.tmpl:16-18`.

**Test scenarios:**
- Rendering both scripts emits a `value:` line carrying the bun version digest.
- Changing only the bun version in a scratch copy of `.chezmoidata/releases.json` changes the rendered fingerprint of both scripts.
- Changing an unrelated tool's version leaves both fingerprints unchanged — this is what distinguishes `values` from globbing the whole lock.

**Verification:** the render comparison above shows the fingerprint moving with bun and only with bun.

---

### U7. Give ~/.agents/plugins its own SELinux type

**Goal:** #393's suppression covers the skills root only, and the plugins root is no longer silently exempted.

**Requirements:** R23.

**Dependencies:** none.

**Files:**
- `system/linux/selinux/dotfiles_protected_agent_configs.cil` (modify)
- `.chezmoiscripts/00-tools/run_onchange_before_00-selinux-policies.sh.tmpl` (modify — relabel and reclaim lists)
- `.ci/test-selinux-protected-configs.sh` (modify)

**Approach:**
1. Declare a new attribute-free type for the plugins root, add its `roletype`, and include it in the `protected_agent_config_type` attribute set so every existing `chezmoi_t` / `unconfined_domain_type` / `locate_t` rule written against the attribute keeps applying unchanged.
2. Repoint the `filecon` at `:340` from `protected_agent_config_t` to the new type. Leave `:339` (skills) alone.
3. Add the new type to the installer's relabel list and to the stale-label reclaim selectors.
4. Update the gate in lock-step. Beyond the token pins, the `expect_context` assertions, the `EXPECTED` / `READ_ONLY` write-boundary matrix, `SANCTIONED_DONTAUDIT` and the mutant expectations, three sites hardcode the current four type names and will silently under-guard the new type if missed:
   - `.ci/test-selinux-protected-configs.sh:224` — the `for protected in ...` base-policy-attribute loop.
   - `:231` — the `(protected_agent_config_t|claude_config_t|gemini_config_t|codex_config_t)` alternation in the "added to an attribute other than `protected_agent_config_type`" check.
   - `:659` — the compiled-policy `PROTECTED` set that `SANCTIONED_DONTAUDIT` is checked against.
   Miss them and a later `(typeattributeset file_type (<new-type>))` makes the plugins root writable by every unconfined process with CI green, and a `dontaudit codex_t <new-type> (dir (write))` re-opens exactly the hole R23 closes, unflagged.
5. Before landing, observe what the narrowed suppression unmasks: rebuild with `dontaudit` disabled (`semodule -DB`), run one Codex session, confirm the denials come from the skills root only, then restore with `semodule -B`. CI reads policy source and observes no runtime behavior, so nothing else answers whether `codex_t` actually writes under `~/.agents/plugins`. Record the observation in the PR body.

**Execution note:** the CI gate compiles the policy with `secilc` and inspects it with `setools`, so a type added to the CIL without the matching gate updates fails loudly — that is the intended order. Do not weaken a mutation test to make the suite pass.

**Patterns to follow:** the existing four-type structure at `:77-88` — the new type must stay attribute-free for the same reason recorded in the module header and in `docs/solutions/security-issues/selinux-user-scope-agent-config-protection.md`: a type carrying `file_type` is writable by every unconfined process.

**Test scenarios:**
- The compiled policy labels `~/.agents/plugins` with the new type and `~/.agents/skills` with `protected_agent_config_t`.
- `codex_t` holds no allow rule on the new type, and the sanctioned `dontaudit` names `protected_agent_config_t` only — so a plugins-root write by `codex_t` is audited again.
- `chezmoi_t` retains full write on the new type via the attribute; `unconfined_domain_type` retains read-only.
- The existing four mutants still fail as designed, plus two new ones: a mutant that re-points the suppression at the new type, and a mutant appending `(typeattributeset file_type (<new-type>))`, which must fail the write-boundary check for the same reason the existing `protected_agent_config_t` file_type mutant does.
- The rendered installer script names both roots in the relabel list and both types in the reclaim selectors.

**Verification:** `.ci/test-selinux-protected-configs.sh` passes, including its compiled-policy matrix and mutation tests.

---

### U8. Make multi-command external units publish resolvable links

**Goal:** `antigravity` runs on a host where it is currently `command not found`, and a declared command name with no backing file fails loudly instead of publishing a dangling link.

**Requirements:** R31.

**Dependencies:** none.

**Files:**
- `.chezmoidata/commands.yaml` (modify — the `agy` unit)
- `packages/command-reconcile/src/reconcile.ts` (modify — resolve guard)
- `packages/command-reconcile/test/reconcile.test.ts` (modify)
- `.ci/test-command-reconcile-apply.sh` (modify)

**Approach:**
1. Declare `relPath: agy` on the `antigravity` command so both public links target the one staged file. `reconcile.ts:42` already honors `cmd.relPath ?? cmd.name`, so this alone repairs the link.
2. Add the guard: before publishing a public link, resolve the target and confirm it both exists and stays inside the store directory — a resolve-and-containment check, not a bare existence check, so a symlink inside staged archive content cannot point out of the store. On a miss, return the existing conflict-shaped failure result naming the unit and command rather than creating the link.
3. Scope the guard to units whose backing path is a completed store directory. `packages/command-reconcile/src/producer.ts:44-57` short-circuits every `mutableTree` unit and returns the raw tree path with no store copy and no `.complete` marker, so the guard must skip them. `flutter` is `producer: existingTree` **and** `mutableTree: true` over `.local/share/flutter/versions`, a tree `.chezmoiscripts/00-tools/run_onchange_after_flutter.sh.tmpl` downloads separately and can skip — without this carve-out the guard would turn a currently-successful reconcile into a reported failure on any host where that SDK tree is absent.
4. Strengthen the tests that let this through: the unit test asserts only `isSymbolicLink()`, and the CI test asserts only `[[ -L ... ]]`.

**Execution note:** the guard is the part that matters beyond this one host — write it first and confirm it fails against the current `commands.yaml`, then apply the data fix and watch it pass.

**Patterns to follow:** the conflict return shape already used in `reconcile.ts` for ownership conflicts; `prune.ts:116,153` for resolving a command path via `cmd.relPath ?? cmd.name`.

**Test scenarios:**
- A two-name external unit whose staging directory holds one file, with `relPath` declared, publishes two links that both resolve.
- The same unit *without* `relPath` returns the guard's failure instead of publishing a dangling link.
- The existing multi-command test, which hand-creates both staged files, still passes — the guard must not reject a genuine multi-binary unit.
- A `mutableTree` unit whose tree is absent still reconciles rather than failing the new guard — `flutter` is the live case.
- The `flutter` unit (both commands carrying `relPath`) is otherwise unaffected.
- The CI apply test asserts link targets exist, not merely that links are links.

**Verification:** `vp run -r test` and `.ci/test-command-reconcile-apply.sh` pass; on a scratch `HOME`, both `agy` and `antigravity` resolve to the same real file.

---

### U9. Content-address the external store identity

**Goal:** an upstream asset re-published under an unchanged tag produces a new store generation instead of leaving the host on the binary it already staged.

**Requirements:** R30.

**Dependencies:** U5 (same digest source; landing U5 first means every covered external already asserts the digest at fetch time).

**Files:**
- `.chezmoitemplates/release-lock-ref.tmpl` (modify — extend `optional:true`; prerequisite)
- `.chezmoitemplates/command-manifest.tmpl` (modify — the `producer: external` identity branch)
- `.ci/test-command-manifest.sh` (modify)

**Approach:**
1. **Prerequisite — extend the accessor first.** `optional:true` does not currently rescue a digest-less unit. `.chezmoitemplates/release-lock-ref.tmpl:67-69` calls `fail` unconditionally when the lock entry has no `artifacts` block or no artifact for the platform; the `$optional` branch at `:71-76` is only reached once the platform artifact map exists. `kubectl`, `helm` and `glab` have no `artifacts` key at all, and `.chezmoidata/commands.yaml` declares four `producer: external` units on them (`kubectl`, `kubectl-convert`, `helm`, `glab`). Without this step every command-manifest render aborts and no host can apply. Extend the accessor so `optional:true` also returns `""` for a missing `artifacts` block or platform. This must happen inside the accessor: its own header declares it the ONLY consumer entry point to the lock, so `command-manifest.tmpl` may not read `.releases` directly.
2. In the `external` branch, resolve the platform-scoped `sha256` with `optional:true`; when it is empty, resolve `sha512` with `optional:true`. `agy` carries a null `sha256` and a populated `sha512`, and it is the one digest-less-by-sha256 unit that actually has a digest.
3. Compose the identity as the version plus a short digest suffix when either digest resolved; fall back to the bare version otherwise, so the four version-only units keep rendering.
4. Keep the identity filesystem-safe — it becomes a directory name under `~/.local/lib/commands/store/<unit>/`.

**Execution note:** this re-keys all 30 external units on the next apply. Confirm before landing that this is a re-copy from the already-populated staging path and not a re-download, and that superseded directories are reclaimed by the existing prune path rather than accumulating. The prune claim holds only because every current `producer: external` unit declares `proofEligible: true` — `packages/command-reconcile/src/prune.ts:104-108` retains rather than reclaims a unit that is not, so a future `proofEligible: false` external would silently accumulate store generations.

**Patterns to follow:** the `producer: build` and `producer: source` branches in the same template, which already compose content-derived identities; `release-lock-ref.tmpl:70-79` for `optional:true`.

**Test scenarios:**
- A unit whose lock entry carries a `sha256` renders an identity containing both the version and a digest suffix.
- The `agy` unit, whose lock records a null `sha256` and a populated `sha512`, also renders a digest suffix rather than falling back to the bare version.
- Each of the four version-only command units — `kubectl`, `kubectl-convert`, `helm`, `glab` — renders the bare version and does not fail. (`winbox` is not a command unit and is not a case here.)
- `bun` and `bunx`, which share `tool: bun`, render the same identity.
- Changing only the digest in a scratch lock changes the identity while the version stays put — this is the behavior #402 asks for.
- Every one of the 30 external units renders without a template error.
- The accessor change is contained: a non-optional call against a missing artifact still fails loudly, so step 1 does not silently weaken the lock's no-live-fallback rule.

**Verification:** `.ci/test-command-manifest.sh` passes for both rendered platforms, and a scratch apply shows a new store directory created and the superseded one reclaimed. Additionally assert that the four harness binaries whose SELinux entrypoint labels are path-pinned — `~/.local/lib/commands/store/{claude,agy,aoe,codex}/<new-identity>/<binary>` — still report `claude_exec_t` / `agy_exec_t` / `aoe_exec_t` / `codex_exec_t` after the re-key. The `filecon` for those paths applies on `restorecon`, which runs on policy change, and U9 changes no policy; if the label does not follow, those harnesses run as `unconfined_t` and lose write access to their own config types.

---

## Verification Contract

Run from the repo root unless stated otherwise. Never apply to the live `$HOME` — use the scratch-destination method in `AGENTS.md` ("Verification").

- **TypeScript workspace** (U1, U8): `vp run -r build`, `vp run -r typecheck`, `vp run -r test` in `packages/`. Tests are Vitest via vite-plus; `packages/command-reconcile/src/producer.ts` currently has no dedicated test file, so U8's guard coverage lands in `test/reconcile.test.ts`.
- **Render gates** (U3, U4, U5, U6, U9): `.ci/test-command-external-render.sh`, `.ci/test-command-manifest.sh`. Render every changed template through `chezmoi execute-template` with the stub-`op` scratch config; scripts are not targets and must be compared as rendered text on both sides.
- **CI structure and the bun ladder** (U2, U5): `.ci/test-ci-wiring.sh` — any gate added by this plan must be invoked by a workflow and, if it lands as a new job, appear in `delivery`'s `needs` — plus `.ci/test-bun-resolve.sh`, which U2 is the only unit to touch.
- **SELinux** (U7): `.ci/test-selinux-protected-configs.sh`, which needs `secilc` and `python3-setools`. It compiles the module and asserts the write-boundary matrix and the mutation set.
- **Command reconciler apply path** (U8, U9): `.ci/test-command-reconcile-apply.sh`, `.ci/test-command-reconcile-process.sh`.
- **Repo hygiene** (all units): `git diff --check`, `git status`, and a diff limited to the requested scope.

Idempotence is the repo's stated quality bar: a second apply on unchanged source must change zero targets and rerun zero onchange scripts. U6 and U9 both touch that property directly and must be checked against it.

## Definition of Done

**Global**
- R25-R31 are implemented on this branch, and each unit's Verification passes. R23 is satisfied upstream by PR #405 and is explicitly out of this branch's scope.
- Every new CI gate is wired and proven able to fail, not merely to pass. A gate that cannot fail is not coverage.
- No mutation test or existing assertion was weakened to make a suite green.
- A second apply against a scratch destination changes zero targets and reruns zero onchange scripts.
- R22, R24 and R32 are recorded as deferred with their evidence, and reported in the PR body rather than dropped. #371 is left open and annotated with its two re-open triggers, not closed as won't-fix.
- U7 and U9 may each land as their own commit or PR; neither blocks the other seven units. A U7 stop-and-report does not hold up R25-R31.
- Abandoned or experimental code from approaches that did not pan out is removed from the diff.

**Per unit**
- U1: `bun` declares `tagPrefix`; the locked version is unchanged by the pin.
- U2: two sourced libraries are `0644`, `apt-install.sh` stays `0755`, rung 1 rejects a relative path, and both ladder copies still declare identical rungs.
- U3: a no-override render is byte-identical to the pre-change render.
- U4: six platform combinations render, and the URL/path agreement assertion demonstrably fails on injected drift.
- U5: every lock-URL-backed external declares a `checksum`; the version-only exceptions are declared, not silently skipped.
- U6: the rendered fingerprint moves with the bun version and not with an unrelated tool.
- U7: **reverted.** Superseded by PR #405 on `main`; this branch asserts only that no second plugins type remains after the merge.
- U8: both `agy` and `antigravity` resolve, and the guard fails a name with no backing file.
- U9: the accessor's `optional:true` covers a missing `artifacts` block; all 30 external units render; `agy` carries a sha512-derived suffix; the four version-only units fall back cleanly; and the four harness store binaries keep their `*_exec_t` labels after the re-key.
