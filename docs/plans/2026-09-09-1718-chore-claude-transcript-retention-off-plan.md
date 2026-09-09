---
title: Claude Code Transcript Retention Off - Plan
type: chore
date: 2026-09-09
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
---

# Claude Code Transcript Retention Off - Plan

## Goal Capsule

- **Objective:** Tokscale이 30일보다 오래된 Claude Code 세션 기록까지 계속 집계한다. 사용량 집계가 로컬 파일 삭제 때문에 끊기지 않는다.
- **Means:** `agents.claude.settings`에 `cleanupPeriodDays` 리프를 선언해 보존 기간을 사실상 무한으로 만든다 (KTD1).
- **Authority:** 이 계획 > 저장소 `AGENTS.md` > 공통 에이전트 지침. 충돌 시 더 좁은 규칙이 우선한다.
- **Execution profile:** 데이터 선언 변경과 그 회귀 가드. 단위 테스트가 아니라 렌더 게이트와 리컨사일러 테스트가 증거다.
- **Stop conditions:** 렌더 게이트가 새 경로를 거부하거나, `.ci/test-claude-settings-reconcile.sh`가 실패하면 멈추고 보고한다.
- **Tail ownership:** 호출한 파이프라인이 커밋, 푸시, MR/PR, CI 감시를 소유한다.

---

## Product Contract

### Summary

`.chezmoidata/agents.yaml`의 `agents.claude.settings`에 `cleanupPeriodDays: 9999999999` 리프를 추가하고, 그 값이 문자열로 퇴화하는 것을 막는 상시 CI 가드를 함께 넣는다. `.chezmoiscripts/70-agents/run_after_config-claude-settings.sh.tmpl`이 매 apply마다 이 값을 live `~/.claude/settings.json`에 assert하므로, Claude Code의 보존 스윕이 어떤 파일도 삭제하지 않게 된다.

### Problem Frame

Claude Code는 `cleanupPeriodDays`의 기본값 30일을 기준으로 세션 기록을 자동 삭제한다. Tokscale은 그 로컬 기록을 읽어 사용량을 집계하므로, 30일이 지난 구간은 원본이 사라져 다시 집계할 수 없다. 이 저장소는 Claude Code 설정을 선언형으로 관리하지만 `cleanupPeriodDays`는 아직 선언되어 있지 않아, 기본 30일이 그대로 적용되고 있다.

### Key Decisions

- 값은 정확히 `9999999999`로 한다 (session-settled: user-directed — chosen over 3650이나 3650000 같은 유한한 큰 값: 사용자가 리텐션을 "사실상 없애기"를 명시적으로 요구했다). Governs R1, R2.
- 설정은 `.chezmoidata/agents.yaml`의 선언형 경로로만 관리하고 live `~/.claude/settings.json`을 직접 편집하지 않는다 (session-settled: user-directed — chosen over live settings.json 직접 편집: live 파일은 chezmoi 타깃이 아니어서 손으로 넣은 값은 관리 대상 밖에 남고 다른 writer가 덮어쓸 수 있다). Governs R1, R4.

### Requirements

**선언**

- R1. `.chezmoidata/agents.yaml`의 `agents.claude.settings`가 `cleanupPeriodDays` 키를 값 `9999999999`로 선언한다.
- R2. 그 값은 따옴표 없는 YAML 정수로 쓰여, 렌더된 JSON에서 문자열이 아닌 숫자로 나타난다.
- R3. 리프 바로 위 주석이 이 값을 넣은 이유, 숫자 타입 요구, 보존 스윕이 더 이상 정리하지 않는 대상, 그리고 Claude Code 버전을 올릴 때 삭제가 재개되지 않는지 확인하라는 지시를 기록한다.

**리컨사일 동작**

- R4. apply 후 live `~/.claude/settings.json`의 `cleanupPeriodDays`가 `9999999999`가 된다.
- R5. 기존 선언 리프와 다른 writer가 소유한 키(`hooks`, `enabledPlugins`, `extraKnownMarketplaces`, 그리고 `modelSettings`와 `env`의 미선언 형제 키)가 변경 없이 살아남는다.
- R6. 값이 이미 수렴한 상태에서 리컨사일러를 다시 돌리면 파일을 다시 쓰지 않는다.

**회귀 방지**

- R7. `.ci/test-claude-settings-reconcile.sh`가 리컨사일 후 파일에서 `cleanupPeriodDays`의 JSON 타입이 숫자가 아니면 이름을 대며 실패한다.
- R8. `AGENTS.md`의 Claude Code 설정 문단이 이 리텐션 핀과 그 부작용을 한 문장으로 기록한다.

### Scope Boundaries

- Tokscale 쪽 설정, 보존 정책, 집계 로직은 건드리지 않는다.
- 다른 하네스(`agy`, `codex`, `omp`)의 설정 선언은 건드리지 않는다.
- `desktopSessionCleanupPeriodDays`는 자체 리더(`xe()`)를 가진 별개 설정이며 이번 범위 밖이다.
- 디스크 사용량 모니터링이나 주기적 정리 도구 도입은 이번 범위 밖이다.

---

## Planning Contract

### Key Technical Decisions

- KTD1. **보존 값을 `9999999999`로 선언한다.** (session-settled: user-directed — chosen over 3650000 이하의 유한한 큰 값: 사용자가 리텐션을 사실상 제거하기를 요구했다.) Claude Code의 스키마는 `z.int().positive()`이고 상한이 없으므로 이 값은 검증을 통과한다. 핀된 2.1.266 번들에서 이 키의 소비 지점을 전수 확인한 결과, 숫자로 읽는 곳은 컷오프 계산 `pS()` 단 하나다 — 나머지는 스키마 정의, 텔레메트리 필드(`periodDays`/`usedDefault`), 그리고 org 정책 관리 여부를 보는 존재 확인(`!== void 0`) 세 곳이다. 값을 clamp하거나 다시 파싱하는 경로는 없다. Governs R1, R2.
  - **Conflict call-out (연구가 찾아낸 부작용, 결정은 유지):** `pS()`의 컷오프는 `new Date(Date.now() - days*86400000)`이다. `9999999999`일은 8.64e17 ms이고 이는 JS `Date`의 표현 범위(±8.64e15 ms)를 넘어, 컷오프가 **Invalid Date**가 된다. 모든 `mtime < cutoff` 비교가 `NaN` 비교로 항상 `false`가 되므로 아무것도 삭제되지 않는다 — 원하는 결과는 얻는다. 다만 이는 설계된 경로가 아니라 `NaN` 비교 의미론에 기댄 결과다. `99999999` 이하의 값이면 컷오프가 유효한 `Date`로 남으면서도 약 27만 년의 보존을 준다. 값 변경은 사용자의 판단 사항이므로 이 계획은 지시받은 값을 그대로 쓴다.
- KTD2. **리프는 따옴표 없는 정수로 쓴다.** `env.*` 리프는 Claude Code가 문자열로만 읽기 때문에 인용 부호가 필수지만, `cleanupPeriodDays`는 정반대다. 문자열로 렌더되면 `z.int()` 검증에 걸려 설정 전체가 거부되고 스윕은 기본 30일로 돌아간다. Governs R2.
- KTD3. **렌더 타임 검증기는 그대로 두고, CI 테스트에는 숫자 타입 가드를 추가한다.** `.chezmoitemplates/claude-settings-validate.tmpl`의 경로 문법, 소유권 목록, 보안 allowlist를 이 키는 모두 통과하므로 검증기 변경은 필요 없다. 그러나 CI는 그대로 두면 안 된다: `assert_declared_present`는 live 값을 **같은 렌더 선언**과 비교하므로 양쪽이 함께 문자열이면 통과하고, 검증기는 컨테이너 값만 거부할 뿐 스칼라 타입을 보지 않는다. 저장소는 `env` 리프에 대해 이미 `assert_env_types_are_strings`라는 상시 검사로 같은 함정을 막아 두었으므로, 그 패턴을 이 키에 적용한다. Governs R4, R5, R6, R7.
- KTD4. **선언 JSON은 스크립트 렌더 결과가 아니라 데이터에서 직접 얻는다.** 리컨사일러는 선언을 `DECLARED="$(decode_b64 '{{ $settings | toJson | b64enc }}')"`로 base64에 담아 렌더하므로 평문 JSON이 스크립트에 남지 않는다. 타입 확인은 `.ci/test-claude-settings-reconcile.sh`가 이미 쓰는 방식 — `chezmoi execute-template <<<'{{ .agents.claude.settings | toJson }}'` — 으로 해야 실행 가능하다. Governs R2, R7.

### Assumptions

- Tokscale은 `~/.claude/projects/`의 세션 기록을 읽는다는 전제로 계획했다. 이 전제의 확인과 되돌림 조건은 Definition of Done이 소유한다.

### System-Wide Impact

`cleanupPeriodDays` 스윕은 세션 기록만 정리하지 않는다. 같은 컷오프를 `~/.claude/tasks/`, `~/.claude/shell-snapshots/`, `~/.claude/backups/`, 도구 결과 파일, `mcp-discovery-cache`, 중단된 데몬의 임시 디렉터리가 함께 쓴다. 다만 `pS(e)`는 호출자가 더 작은 `maxAgeDays`를 넘기면 그 값을 쓰므로, 자체 상한을 가진 스윕 갈래는 여전히 정리된다. 상한 없이 무한히 자라는 것은 `cleanupPeriodDays`만 보는 갈래들이고, 그 중 압도적으로 큰 것이 세션 기록이다.

`AGENTS.md`는 load-bearing 리프를 이름으로 열거하는 관행을 이미 갖고 있다 — `env.DISABLE_AUTOUPDATER`를 근거와 함께 지목하고, `theme`/`editorMode`/`verbose`/`permissions.defaultMode`를 미선언 사유와 함께 적는다. 이 리텐션 핀도 같은 자리에 한 문장으로 남긴다 (R8).

### Risks & Dependencies

- **디스크 증가.** 측정 기준(이 계획 작성 시점): 스윕 대상 디렉터리 합계는 약 409 MB이고, 그 중 최근 30일에 쓰인 분량이 약 406 MiB다. 즉 현재 사용 패턴에서 월 약 400 MB, 연 약 5 GB가 더는 회수되지 않는다. 되돌리는 비용은 선언 한 줄 삭제와 apply 한 번이므로, 완화 도구 도입은 범위 밖으로 둔다.
- **`NaN` 비교 의존.** KTD1의 conflict call-out 참고. Claude Code가 컷오프 유효성 검사를 추가하면 삭제가 조용히 재개된다. 이 저장소는 Claude Code 버전을 `.chezmoidata/releases.json`으로 핀하므로 변화는 버전 범프 시점에만 들어오고, 그 시점에 재확인하라는 지시는 리프 주석(R3)에 남는다.
- **공동 writer.** `~/.claude/settings.json`은 Claude Code 자신, aoe, `install-claude-plugins`가 함께 쓴다. 리컨사일러의 리프 단위 assert와 동시 쓰기 감지가 이를 이미 처리한다.

---

## Implementation Units

### U1. `cleanupPeriodDays` 리프 선언

- **Goal:** `agents.claude.settings`에 보존 해제 값을 선언하고, 그 이유·타입 요구·부작용·재확인 지시를 리프 주석과 `AGENTS.md`에 남긴다.
- **Requirements:** R1, R2, R3, R4, R5, R6, R8 (KTD1, KTD2, KTD3)
- **Dependencies:** 없음
- **Files:**
  - `.chezmoidata/agents.yaml` — `agents.claude.settings` 맵에 리프 추가, 리프 바로 위 주석
  - `AGENTS.md` — Claude Code 설정 문단에 리텐션 핀 한 문장
- **Approach:**
  1. `agents.claude.settings` 맵에 `cleanupPeriodDays: 9999999999`를 추가한다. 따옴표를 붙이지 않는다 (KTD2).
  2. 그 리프 **바로 위**에 주석을 붙인다 — `env.DISABLE_AUTOUPDATER`가 자기 타입 함정을 자기 자리에서 기록한 것과 같은 배치다. 주석은 네 가지를 담는다: 이 값이 보존을 사실상 없애 Tokscale이 30일 이후에도 집계하게 한다는 것; `env` 리프와 달리 이 값은 JSON 숫자여야 하며 따옴표를 붙이면 설정이 거부된다는 것; 이 스윕이 세션 기록 외에 `tasks`, `shell-snapshots`, `backups`, 도구 결과 파일도 정리하므로 그 경로들이 더는 줄지 않는다는 것; 이 값이 Claude Code의 `Invalid Date` 컷오프 동작에 기대므로 `.chezmoidata/releases.json`의 Claude Code 버전을 올릴 때 삭제가 재개되지 않는지 확인해야 한다는 것.
  3. `AGENTS.md`의 Claude Code 설정 문단에 한 문장을 더한다: 리텐션이 `cleanupPeriodDays` 리프로 꺼져 있고, 그 대가는 스윕 대상 경로의 무한 증가이며, 숫자 타입은 `.ci/test-claude-settings-reconcile.sh`가 지킨다.
- **Execution note:** 설정 선언 변경이다. 단위 테스트 대신 렌더 게이트와 리컨사일러 테스트로 증명한다.
- **Patterns to follow:** 같은 맵의 `env.DISABLE_AUTOUPDATER` 항목 — 리프 옆 주석에 타입 함정과 근거를 남기고, `AGENTS.md`가 그 리프를 이름으로 다시 지목하는 방식.
- **Test scenarios:**
  - 선언 타입: 스텁 `op`, 빈 config, 임시 destination, `--source "$PWD"` 환경에서 `chezmoi execute-template <<<'{{ .agents.claude.settings | toJson }}'`의 출력에 대해 `jq -r '.cleanupPeriodDays | type'`이 `number`다 (`string`이면 실패).
  - 렌더 게이트: 같은 환경에서 `run_after_config-claude-settings.sh.tmpl`이 성공적으로 렌더된다 (선언 JSON은 base64에 담기므로 렌더 결과에서 평문 grep으로 값을 찾지 않는다 — KTD4).
  - 신규 파일: `cleanupPeriodDays`가 없는 픽스처에 리컨사일러를 돌리면 그 키가 숫자 `9999999999`로 기록된다.
  - 형제 보존: `hooks`, `enabledPlugins`, `extraKnownMarketplaces`, 그리고 `modelSettings`와 `env`의 미선언 형제 키가 실행 후에도 바이트 동일하게 남는다.
  - 수렴: 이미 값이 맞는 파일에 다시 돌리면 stdout이 비고 inode와 mtime이 그대로다.
- **Verification:** `.ci/test-claude-settings-reconcile.sh`가 렌더된 스크립트에 대해 모든 assertion을 통과한다.

### U2. 숫자 타입 상시 CI 가드

- **Goal:** 나중에 누가 이 값에 따옴표를 붙이면 CI가 이름을 대며 실패하게 한다.
- **Requirements:** R7 (KTD3, KTD4)
- **Dependencies:** U1
- **Files:**
  - `.ci/test-claude-settings-reconcile.sh` — 숫자 타입 sweep과 그 실패 분기 픽스처
- **Approach:**
  1. `assert_env_types_are_strings`와 같은 형태로 `cleanupPeriodDays`의 JSON 타입을 검사하는 헬퍼를 더한다. 리컨사일 후 파일에서 그 값이 숫자가 아니면 키 이름을 대며 실패한다.
  2. 기존 sweep들이 그렇듯 **실패 분기를 손으로 만든 픽스처로 강제한다.** 오늘의 올바른 선언만 통과시키면 실패 경로가 CI에서 한 번도 실행되지 않아, 이 가드가 조용히 죽어도 알 수 없다. 문자열 값을 담은 픽스처가 플래그되는지, 올바른 숫자 픽스처가 플래그되지 않는지, 키가 아예 없는 파일이 플래그되지 않는지를 각각 확인한다.
  3. 이미 존재하는 실행 지점(`drift run`, `missing target`, `empty target`, `env co-writer`)에 이 검사를 붙여, 새 리프가 별도 실행 없이 커버되게 한다.
- **Execution note:** 이 가드의 가치는 실패할 때에만 나온다. 먼저 문자열 픽스처로 실패하는 것을 보고, 그다음 통과 경로를 붙인다.
- **Patterns to follow:** 같은 파일의 `env_type_offenders` / `assert_env_types_are_strings`와 그 아래 `mistyped_number`·`mistyped_scalar`·`env_clean`·`env_absent` 픽스처 4종.
- **Test scenarios:**
  - 문자열 값을 담은 손수 만든 픽스처에서 헬퍼가 `cleanupPeriodDays`를 이름으로 플래그한다.
  - 숫자 값을 담은 픽스처에서 아무것도 플래그하지 않는다.
  - 그 키가 없는 픽스처에서 아무것도 플래그하지 않는다.
  - 실제 선언으로 리컨사일된 파일(`drift run`, `missing target`, `empty target`)에서 검사가 통과한다.
- **Verification:** `.ci/test-claude-settings-reconcile.sh`가 전체 통과하고, 선언을 일시적으로 따옴표 씌워 렌더하면 그 실행이 실패한다.

---

## Verification Contract

`AGENTS.md`의 검증 규칙을 그대로 따른다. live `$HOME`에는 절대 배포하지 않는다. 스크래치 디렉터리, 스텁 `op`, 빈 config, 임시 destination, `--source "$PWD"`, 시스템 디렉터리만 담은 `PATH`가 모든 실행에 필수다.

| 게이트 | 명령 | 적용 |
|---|---|---|
| 타입 확인 | 스텁 환경에서 `chezmoi execute-template <<<'{{ .agents.claude.settings \| toJson }}'` 출력에 `jq -e '.cleanupPeriodDays \| type == "number"'` | U1 |
| 렌더 게이트 | 같은 환경에서 `chezmoi execute-template < .chezmoiscripts/70-agents/run_after_config-claude-settings.sh.tmpl` | U1 |
| 리컨사일러 테스트 | 렌더된 스크립트 경로를 인자로 `.ci/test-claude-settings-reconcile.sh` | U1, U2 |
| 가드 실패 분기 | 선언을 일시적으로 문자열로 바꿔 렌더하면 리컨사일러 테스트가 `cleanupPeriodDays`를 이름으로 대며 실패한다 | U2 |
| 범위 확인 | `git diff --check`, `git status`, 변경 범위 제한 diff | U1, U2 |
| CI | 푸시 후 `render-dotfiles.yml`과 `ci.yml`을 terminal success까지 감시 | 전체 |

---

## Definition of Done

- R1부터 R8까지 모두 참이다.
- U1과 U2의 모든 테스트 시나리오가 통과한다.
- `git diff`가 `.chezmoidata/agents.yaml`, `.ci/test-claude-settings-reconcile.sh`, `AGENTS.md` 외의 파일을 보여주지 않는다.
- 시도했다가 버린 코드나 임시 픽스처가 diff에 남아 있지 않다.
- KTD1의 conflict call-out이 사용자에게 보고된다 — 값은 지시대로 유지하되, `Invalid Date` 경로에 의존한다는 사실을 알린다.
- apply 이후 Tokscale이 `~/.claude/projects/`의 세션 기록을 실제로 읽어 집계하는지 사용자가 확인한다. 읽지 않는 것으로 확인되면 `cleanupPeriodDays` 선언을 되돌린다 — 그 경우 이 변경은 목적 없이 디스크만 소모한다.
- `render-dotfiles.yml`과 `ci.yml`이 terminal success에 도달한다.

---

## Sources / Research

- `.chezmoidata/agents.yaml` — `agents.claude.settings` 선언 블록과 그 소유권 주석.
- `.chezmoitemplates/claude-settings-validate.tmpl` — 경로 문법, 리프 전용 규칙, 소유권 거부 목록, 보안 allowlist. 스칼라 타입은 검사하지 않는다.
- `.chezmoiscripts/70-agents/run_after_config-claude-settings.sh.tmpl` — 리프 단위 assert, base64 `DECLARED`, 차단 경로 처리, 동시 쓰기 감지.
- `.ci/test-claude-settings-reconcile.sh` — 선언을 `chezmoi execute-template`로 동적으로 읽는 방식, `assert_env_types_are_strings`와 그 실패 분기 픽스처 4종.
- Claude Code 2.1.266 번들 — 설정 스키마 `cleanupPeriodDays: z.int().positive().optional()`; 최소값 1 검증 메시지; 이 키의 소비 지점 전수 확인 결과 숫자 읽기는 컷오프 계산 `pS()` 하나뿐이고 나머지는 텔레메트리 필드와 org 정책 존재 확인 세 곳; `pS()`의 `maxAgeDays` 인자로 더 작은 상한을 받는 스윕 갈래; 별도 키 `desktopSessionCleanupPeriodDays`의 자체 리더 `xe()`.
- `AGENTS.md` — 검증 절차, 단일 진실 공급원 표, load-bearing 리프를 이름으로 열거하는 관행.
