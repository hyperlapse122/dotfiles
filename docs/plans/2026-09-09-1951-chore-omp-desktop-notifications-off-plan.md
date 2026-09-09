---
title: omp Desktop Notifications Off - Plan
type: chore
date: 2026-09-09
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
---

# omp Desktop Notifications Off - Plan

## Goal Capsule

- **Objective:** 관리 대상 호스트에서 apply를 거친 omp이 데스크톱 알림을 띄우지 않는다. `orchestration` skill이 omp worker를 dispatch할 때마다 turn 종료 알림이 쌓이던 방해가 사라진다.
- **Means:** `agents.omp.settings`에 omp의 알림 스키마 키 세 개(`completion.notify`, `error.notify`, `ask.notify`)를 `"off"`로 선언하고, 그 선언을 지키는 CI 가드를 함께 넣는다 (KTD1).
- **Authority:** 이 계획 > 저장소 `AGENTS.md` > 공통 에이전트 지침. 충돌 시 더 좁은 규칙이 우선한다.
- **Execution profile:** 데이터 선언 변경과 그 회귀 가드. 단위 테스트가 아니라 렌더 게이트와 리컨사일러 테스트가 증거다.
- **Stop conditions:** 렌더 게이트가 새 경로를 거부하거나, `.ci/test-omp-settings-reconcile.sh`가 실패하면 멈추고 보고한다.
- **Tail ownership:** 호출한 파이프라인이 커밋, 푸시, MR/PR, CI 감시를 소유한다.

---

## Product Contract

### Summary

`.chezmoidata/agents.yaml`의 `agents.omp.settings`에 omp의 알림 enum 세 개를 모두 `"off"`로 선언한다. `.chezmoiscripts/70-agents/run_after_config-omp-settings.sh.tmpl`이 매 apply마다 이 값을 live `~/.omp/agent/config.yml`에 assert하므로, omp이 `notify-send`/`gdbus`(Linux)나 `osascript`(macOS)로 데스크톱 알림을 보내는 경로가 전부 닫힌다. 선언이 조용히 소실되거나 값이 뒤집히는 것을 막는 상시 CI 가드를 `.ci/test-omp-settings-reconcile.sh`에 추가하고, `AGENTS.md`의 omp 설정 문단에 이 핀을 한 문장으로 기록한다.

보장의 경계는 apply 시점이다. `~/.omp/agent/config.yml`은 chezmoi 타깃이 아니라 리컨사일 대상이므로, omp이 `/settings`로 알림을 다시 켜면 그 값은 다음 apply까지 살아 있다가 그때 되돌아온다. 선언은 상시 잠금이 아니라 apply마다 다시 세우는 기준선이다.

### Problem Frame

이 워크스테이션에서 omp의 유일한 사용처는 `orchestration` skill을 통한 subagent dispatch다. 사람이 omp의 TUI 앞에 앉아 있는 경우가 없는데도, omp은 turn이 끝날 때마다 데스크톱 알림을 띄운다. worker 하나가 끝날 때마다 알림이 하나씩 쌓이므로, 알림은 정보가 아니라 순수한 소음이다.

omp 18.1.15의 설정 스키마에서 데스크톱 알림을 내보내는 키는 정확히 세 개다 — `completion.notify`(기본 `on`, "Notify when the agent finishes a turn"), `ask.notify`(기본 `on`), `error.notify`(기본 `off`). 셋 다 `agents.omp.settings`에 선언되어 있지 않고, live `~/.omp/agent/config.yml`에도 없다. 즉 지금은 전부 omp의 기본값으로 동작하고 있고, 그래서 `completion.notify`와 `ask.notify`가 켜져 있다.

### Key Decisions

- 알림은 omp 자신의 설정으로 끈다 (session-settled: user-directed — chosen over 데스크톱 환경의 알림 규칙이나 알림 데몬 차단: 사용자가 "omp의 설정을 바꿔서"라고 명시했고, OS 쪽 차단은 이 저장소가 관리하지 않는 상태에 의존한다). Governs R1, R2, R3.
- 알림 세 종류를 선별하지 않고 전부 끈다 (session-settled: user-directed — chosen over `completion.notify`만 끄기: omp의 유일한 사용처가 무인 subagent dispatch라 error/ask 알림도 볼 사람이 없다). Governs R2, R3.
- 값은 `.chezmoidata/agents.yaml`의 선언형 경로로만 관리하고 live `~/.omp/agent/config.yml`을 직접 편집하지 않는다 (session-settled: user-directed — chosen over live config.yml 직접 편집: 그 파일은 chezmoi 타깃이 아니고 omp이 `/settings`와 first-run setup으로 다시 쓰므로, 손으로 넣은 값은 관리 대상 밖에 남는다). Governs R1, R6.

### Requirements

**선언**

- R1. `.chezmoidata/agents.yaml`의 `agents.omp.settings`가 `completion.notify`를 값 `"off"`로 선언한다.
- R2. 같은 맵이 `error.notify`를 값 `"off"`로 선언한다.
- R3. 같은 맵이 `ask.notify`를 값 `"off"`로 선언한다.
- R4. 세 값 모두 따옴표를 붙인 YAML 문자열로 쓰여, 렌더된 JSON에서 문자열 `"off"`로 나타난다.
- R5. 세 리프 바로 위 주석이 이 값을 넣은 이유(무인 subagent 전용 사용처), 이미 기본값이 `off`인 `error.notify`까지 선언하는 이유, 그리고 이 세 개가 omp의 데스크톱 알림 표면 전부라는 사실을 기록한다.

**리컨사일 동작**

- R6. apply 후 live `~/.omp/agent/config.yml`에서 세 키가 모두 `off`가 된다.
- R7. 기존 선언 경로(`startup.setupWizard`, `setupVersion`, `symbolPreset`, `enabledModels`, `disabledProviders`, `modelRoles`)와 omp이 그 옆에 쓴 미선언 키가 변경 없이 살아남는다.
- R8. 세 값이 이미 수렴한 상태에서 리컨사일러를 다시 돌리면 그 경로에 대해 `omp config set`을 호출하지 않는다.

**회귀 방지**

- R9. `.ci/test-omp-settings-reconcile.sh`가 세 알림 경로 중 하나라도 선언에서 사라지거나 값이 문자열 `"off"`가 아니면 그 경로 이름을 대며 실패한다.
- R10. 같은 테스트가 미수렴 픽스처에서 세 경로에 대한 `omp config set <path> off` 호출이 실제로 일어나는지 확인한다.
- R11. `AGENTS.md`의 omp 설정 문단이 이 알림 핀과 그 근거를 한 문장으로 기록한다.
- R12. 이 호스트에 설치된 omp의 설정 스키마를 읽기 전용으로 열거해, 이름이 `*.notify`인 키가 `completion.notify`/`error.notify`/`ask.notify` 셋뿐임을 확인한 결과가 완료 근거로 기록된다. 그 확인이 pin된 omp 버전에 묶인다는 사실과 버전 범프 때 다시 확인하라는 지시가 R5의 리프 주석에 남는다.

### Scope Boundaries

- `recap.enabled`와 `recap.idleSeconds`는 omp UI에서 같은 "Notifications" 그룹에 묶여 있지만 데스크톱 알림이 아니라 터미널 내 LLM 요약이다. 범위 밖이다.
- `ask.timeout`도 같은 그룹이지만 알림이 아니라 자동 선택 타임아웃이다. 범위 밖이다.
- `mcp.notifications` / `mcp.notificationDebounceMs`는 MCP 리소스 업데이트를 대화에 주입하는 설정이고 데스크톱 알림과 무관하다. 범위 밖이다.
- 다른 하네스(`claude`, `agy`, `codex`)의 알림 설정은 건드리지 않는다. `agents.claude.settings`의 `inputNeededNotifEnabled` / `agentPushNotifEnabled`는 Claude Code의 별개 표면이며 이번 변경 대상이 아니다.
- omp haptic 플러그인, 사운드, OS 알림 규칙은 범위 밖이다.
- `.chezmoitemplates/omp-settings-validate.tmpl`은 변경하지 않는다 (KTD4).
- 호스트별 분기는 하지 않는다. `agents.omp.settings`에는 `gate:` 문법이 없고, `AGENTS.md`가 기록하듯 관리 대상 호스트는 모두 같은 운영자 한 사람의 워크스테이션이다. 따라서 이 선언은 관리 대상 전체에 동일하게 적용되며, 호스트별 알림 정책을 두려면 그것은 선언 문법을 추가하는 별개의 작업이다.

### Deferred to Follow-Up Work

- `AGENTS.md` 69번 문단은 `startup.setupWizard`와 `setupVersion`을 "the one non-model exception"이라 부르지만 실제로는 `symbolPreset`도 함께 선언되어 있어 이미 정확하지 않다. 이번 변경은 그 문장에 알림 핀을 더하면서 열거를 맞추는 선에서 끝내고, 문단 전체 재작성은 하지 않는다.

---

## Planning Contract

### Key Technical Decisions

- KTD1. **세 개의 알림 enum을 모두 `off`로 선언한다.** omp 18.1.15의 설정 스키마에서 `ui.group: "Notifications"`인 항목은 `completion.notify`, `error.notify`, `ask.timeout`, `ask.notify`, `recap.enabled`, `recap.idleSeconds` 여섯 개이고, 그중 데스크톱 알림을 실제로 내보내는 것은 이름이 `*.notify`인 세 개뿐이다. 세 개 모두 `type: "enum", values: ["on","off"]`이므로 `off`는 스키마가 인정하는 값이다. `error.notify`의 기본값은 이미 `off`지만, 이 저장소의 리컨사일러는 **미선언 키를 건드리지 않으므로** 선언하지 않으면 `/settings`에서 한 번 켠 값이 다음 apply에도 살아남는다 — 선언이 곧 핀이다. Governs R1, R2, R3.
- KTD2. **값은 따옴표를 붙인 YAML 문자열로 쓰되, 가드는 따옴표가 아니라 렌더 결과의 타입과 값에 건다.** `off`는 YAML 1.1이 불리언으로 해석하는 토큰이지만, 이 저장소가 쓰는 파서(chezmoi/go-yaml v3)는 계획 작성 시점에 확인한 결과 unquoted `off`를 문자열 `"off"`로 남긴다 — 즉 오늘 이 파서에서 따옴표는 렌더 결과를 바꾸지 않는다. 따라서 "따옴표를 떼면 CI가 실패한다"는 성립하지 않으며, 그것을 실패 시나리오로 쓰면 절대 실패하지 않는 테스트가 된다. 따옴표는 이 값이 불리언이 아니라 enum 토큰이라는 사실을 선언 자체에서 읽히게 하는 **표기 관례**로 유지하고, 실제 가드는 렌더된 값의 JSON 타입이 `string`이고 값이 `off`인지를 본다 — 파서가 바뀌어 불리언이 되든 값이 `on`으로 뒤집히든 그 검사가 잡는다. Governs R4, R9.
- KTD3. **CI 가드는 렌더 표면 needle과 값 타입 검사 둘 다로 건다.** `.ci/test-omp-settings-reconcile.sh`는 이미 렌더된 스크립트에서 `"startup.setupWizard"`, `"enabledModels"`, `"symbolPreset": "nerd"` 같은 needle을 grep하는 sweep을 갖고 있다. 이 리컨사일러는 선언을 base64가 아니라 **평문 heredoc JSON**으로 렌더하므로(`{{ $settings | toPrettyJson }}`), needle grep이 이 파일에서는 그대로 통한다. 다만 needle만으로는 문자열/불리언 구분이 되지 않으므로, `chezmoi execute-template <<<'{{ .agents.omp.settings | toJson }}'`으로 데이터에서 직접 읽어 세 경로의 JSON 타입이 `string`이고 값이 `off`인지 확인하는 검사를 함께 넣는다 — `.ci/test-claude-settings-reconcile.sh`가 `cleanupPeriodDays`에 대해 쓰는 것과 같은 패턴이다. Governs R9, R10.
- KTD4. **렌더 타임 검증기는 그대로 둔다.** `.chezmoitemplates/omp-settings-validate.tmpl`의 경로 문법(`^[A-Za-z][A-Za-z0-9_-]*([.][A-Za-z][A-Za-z0-9_-]*)*$`)을 세 경로 모두 통과하고, 헤드 `completion`/`error`/`ask`는 거부 목록(`plugins`, `marketplaces`, `mcpServers`)에 없으며, 값이 null도 아니고 `modelRoles`/`enabledModels` 특수 처리 대상도 아니다. 검증기 변경은 불필요하다.
- KTD5. **리컨사일러의 `unknown` 분기는 이 경로들에서 발동하지 않는다.** 리컨사일러는 `omp config list --json`이 보고하지 않는 선언 경로를 오타로 보고 apply를 실패시킨다. 이 호스트의 omp 18.1.15에서 `config list --json`은 세 키를 모두 — 기본값 상태에서도 — 평평한 점 표기 키로 보고하므로(`{"completion.notify":{"value":"on","type":"enum",...}}`), 비교는 `equal`/`differs`로만 갈린다. Governs R6, R8.

### System-Wide Impact

이 변경으로 omp은 turn 종료, 에러, ask 대기 어느 경우에도 데스크톱 알림을 띄우지 않는다. omp을 사람이 직접 대화형으로 쓰는 상황이 생기면 ask 대기를 알림으로 알 수 없다 — 화면을 봐야 한다. 이 워크스테이션의 omp 사용처가 `orchestration` dispatch 하나뿐이라는 전제 위에서 받아들인 대가이며, 되돌리는 비용은 선언 세 줄 중 필요한 것을 지우고 apply 한 번이다.

리컨사일러는 선언 경로 단위로 assert하므로, 이번에 추가되는 세 경로는 기존 모델 정책 선언과 서로 독립적이다. 한 경로의 assert 실패는 그 경로만 실패시킨다.

### Risks & Dependencies

- **omp 버전 범프.** 알림 키 이름이나 enum 값이 바뀌면 리컨사일러의 `unknown` 분기가 apply를 실패시킨다 — 조용한 실패가 아니라 이름을 대는 실패이므로 감지 가능하다. omp 버전은 `.chezmoidata/releases.json`으로 핀되어 있어 변화는 범프 시점에만 들어온다.
- **omp이 알림 경로를 새로 추가하는 경우.** 이번 선언은 오늘의 스키마가 가진 세 개를 닫는다. 새 알림 키가 생기면 기본값으로 켜질 수 있고, 이 계획의 가드는 그것을 잡지 못한다. 그때는 같은 자리에 한 줄을 더하는 것이 전부다.
- **공동 writer.** `~/.omp/agent/config.yml`은 omp 자신이 `/model`, `/settings`, first-run setup으로 쓴다. 리컨사일러의 read-then-compare와 경로 단위 assert가 이미 이를 처리한다.

---

## Implementation Units

### U1. 알림 리프 세 개 선언

- **Goal:** `agents.omp.settings`에 omp의 데스크톱 알림 표면 전부를 `off`로 선언하고, 그 근거를 리프 주석과 `AGENTS.md`에 남긴다.
- **Requirements:** R1, R2, R3, R4, R5, R11, R12 (KTD1, KTD2, KTD4, KTD5)
- **Dependencies:** 없음
- **Files:**
  - `.chezmoidata/agents.yaml` — `agents.omp.settings` 맵에 세 리프 추가, 그 위 주석
  - `AGENTS.md` — omp 설정 문단에 알림 핀 한 문장
- **Approach:**
  1. `agents.omp.settings` 맵에 `completion.notify: "off"`, `error.notify: "off"`, `ask.notify: "off"` 세 항목을 추가한다. 기존 항목들이 그렇듯 비모델 스칼라는 맵 앞쪽에 모여 있으므로, `symbolPreset` 다음이자 `enabledModels` 앞에 둔다.
  2. 세 항목 **바로 위**에 주석을 붙인다 — `.chezmoidata/agents.yaml`이 `env.DISABLE_AUTOUPDATER`와 `cleanupPeriodDays`에서 이미 쓰는, 함정과 근거를 리프 옆에 남기는 배치다. 주석은 다섯 가지를 담는다: 이 호스트의 omp 사용처가 `orchestration` subagent dispatch뿐이라 turn 종료 알림이 소음이라는 것; 이 세 개가 **pin된 omp 버전의 설정 스키마에서 확인한** 데스크톱 알림 표면 전부이고 나머지 "Notifications" 그룹 항목(`ask.timeout`, `recap.*`)은 알림이 아니라는 것; 그 확인이 버전에 묶이므로 `.chezmoidata/releases.json`의 omp 버전을 올릴 때 새 `*.notify` 키가 생겼는지 다시 확인해야 한다는 것; `error.notify`는 기본값이 이미 `off`지만 미선언 키는 다음 apply에서 되돌아오지 않으므로 선언이 곧 핀이라는 것; 값은 불리언이 아니라 enum 토큰이므로 따옴표를 표기 관례로 유지하고 실제 타입/값은 `.ci/test-omp-settings-reconcile.sh`가 지킨다는 것.
  3. 알림 표면 전수 확인을 읽기 전용으로 수행하고 그 결과를 기록한다 (R12): `omp config list --json`의 키 목록에서 `*.notify`로 끝나는 항목이 선언한 세 개뿐인지 확인한다. 이 명령은 읽기이므로 live `$HOME`에 아무것도 배포하지 않는다.
  4. `AGENTS.md`의 omp 설정 문단(모델 배치를 설명하는 문단)에 한 문장을 더한다: 비모델 예외 열거에 알림 핀을 포함시키고, 무인 dispatch 전용 사용처라는 근거와 대가(대화형으로 쓸 때 ask 대기를 알림으로 알 수 없음)를 적는다.
- **Execution note:** 설정 선언 변경이다. 단위 테스트 대신 렌더 게이트와 리컨사일러 테스트로 증명한다.
- **Patterns to follow:** 같은 파일의 `agents.claude.settings` 내 `cleanupPeriodDays` 항목 — 리프 옆 주석에 근거와 타입 함정을 남기고, `AGENTS.md`가 그 리프를 이름으로 다시 지목하는 방식.
- **Test scenarios:**
  - 선언 타입: 스텁 `op`, 빈 config, 임시 destination, `--source "$PWD"` 환경에서 `chezmoi execute-template <<<'{{ .agents.omp.settings | toJson }}'`의 출력에 대해 `jq -r '."completion.notify" | type'`이 `string`이고 값이 `off`다. `error.notify`, `ask.notify`도 같다.
  - 렌더 게이트: 같은 환경에서 `.chezmoiscripts/70-agents/run_after_config-omp-settings.sh.tmpl`이 성공적으로 렌더된다 — 즉 `omp-settings-validate.tmpl`이 세 경로를 거부하지 않는다.
  - 렌더 표면: 렌더된 스크립트의 heredoc JSON에 `"completion.notify": "off"`가 문자 그대로 나타난다.
  - 알림 표면 전수 확인: `omp config list --json`의 키 중 `*.notify`로 끝나는 것이 `completion.notify`, `error.notify`, `ask.notify` 셋뿐이다 (R12).
- **Verification:** 렌더 게이트와 선언 타입 확인이 통과하고, R12의 전수 확인 결과가 기록된다. 리컨사일 동작(R6·R7·R8)의 증거는 U2가 추가하는 픽스처 실행이 소유하며, 이 계획은 live `$HOME`에 apply해 확인하지 않는다.

### U2. 선언을 지키는 상시 CI 가드

- **Goal:** 나중에 누가 세 경로 중 하나를 지우거나 값을 뒤집거나 문자열이 아닌 타입으로 만들면 CI가 그 경로 이름을 대며 실패하게 하고, 리컨사일 동작(R6·R7·R8)의 증거를 픽스처 실행으로 확보한다.
- **Requirements:** R6, R7, R8, R9, R10 (KTD2, KTD3, KTD5)
- **Dependencies:** U1
- **Files:**
  - `.ci/test-omp-settings-reconcile.sh` — 렌더 표면 needle 세 개, 선언 타입/값 sweep, 미수렴 픽스처의 호출 확인
- **Approach:**
  1. 파일 상단의 `for needle in ... do grep -F` 목록에 `"completion.notify": "off"`, `"error.notify": "off"`, `"ask.notify": "off"` 세 needle을 더한다. 이 리컨사일러는 선언을 평문 heredoc으로 렌더하므로 needle grep이 실제로 값을 본다 (KTD3).
  2. 데이터에서 직접 읽는 타입/값 검사를 더한다. `chezmoi execute-template <<<'{{ .agents.omp.settings | toJson }}'`의 출력에 대해 세 경로의 `type`이 `string`이고 값이 `off`인지 확인하고, 아니면 어긋난 경로 이름과 실제 타입을 함께 출력하며 실패한다. needle grep은 렌더된 텍스트를, 이 검사는 데이터 타입을 보므로 둘은 서로를 대체하지 않는다.
  3. **실패 분기를 손으로 만든 픽스처로 강제한다.** 오늘의 올바른 선언만 통과시키면 실패 경로가 CI에서 한 번도 실행되지 않아, 가드가 조용히 죽어도 알 수 없다. 불리언 값을 담은 픽스처가 플래그되는지, 값이 `on`인 픽스처가 플래그되는지, 경로가 아예 없는 픽스처가 플래그되는지를 각각 확인한다. 따옴표를 떼는 것은 실패 시나리오가 **아니다** — 오늘의 파서에서 렌더 결과가 같으므로 절대 실패하지 않는 테스트가 된다 (KTD2).
  4. 세 키가 `on`인 live 픽스처를 추가하고, 리컨사일러가 그 세 경로에 대해 `config set ... off`를 호출하는지 기존 `$state` 파일 확인 방식으로 검증한다. 이미 `off`인 픽스처에서는 호출이 없어야 한다 (R8).
  5. **호출뿐 아니라 결과 상태도 확인한다.** 스텁 `omp`이 `config set`을 받은 뒤의 상태를 픽스처 config에 반영하게 하고, 실행 후 세 경로의 값이 모두 `off`인지(R6), 그리고 기존 선언 경로와 미선언 형제 키가 바이트 동일하게 남았는지(R7)를 확인한다. 호출 목록만 보면 리컨사일러가 값을 쓰지 못한 경우를 놓친다.
- **Execution note:** 이 가드의 가치는 실패할 때에만 나온다. 먼저 불리언 픽스처로 실패하는 것을 보고, 그다음 통과 경로를 붙인다.
- **Patterns to follow:** 같은 파일의 렌더 표면 needle 루프와 `reset()` / `$calls` / `$state` 픽스처 구조. 타입 검사는 `.ci/test-claude-settings-reconcile.sh`의 `assert_env_types_are_strings`와 그 실패 분기 픽스처 4종.
- **Test scenarios:**
  - 세 경로 중 하나가 빠진 선언에서 needle grep이 그 경로 이름을 대며 실패한다.
  - 값이 불리언 `false`로 렌더되는 픽스처에서 타입 검사가 경로 이름과 실제 타입(`boolean`)을 대며 실패한다.
  - 값이 `on`인 픽스처에서 값 검사가 실패한다.
  - 오늘의 실제 선언에서는 needle grep과 타입 검사가 모두 통과한다.
  - 세 키가 `on`인 live 픽스처 실행 후 `$state`에 `config set completion.notify off`, `config set error.notify off`, `config set ask.notify off`가 각각 정확히 한 줄씩 남는다.
  - 같은 실행이 끝난 뒤 픽스처 config의 세 경로 값이 모두 `off`다 (R6).
  - 같은 실행이 끝난 뒤 기존 선언 경로와 미선언 형제 키가 바이트 동일하게 남아 있다 (R7).
  - 세 키가 `off`인 live 픽스처 실행 후 `$state`에 그 세 경로에 대한 줄이 하나도 없다 (R8).
  - 세 키 중 하나를 보고하지 않는 live 픽스처에서 리컨사일러가 그 경로를 오타로 지목하며 실패한다 (KTD5의 `unknown` 분기).
- **Verification:** `.ci/test-omp-settings-reconcile.sh`가 전체 통과하고, 선언 값을 일시적으로 `on`이나 불리언으로 바꿔 렌더하면 그 실행이 경로 이름을 대며 실패한다.

---

## Verification Contract

`AGENTS.md`의 검증 규칙을 그대로 따른다. live `$HOME`에는 절대 배포하지 않는다. 스크래치 디렉터리, 스텁 `op`, 빈 config, 임시 destination, `--source "$PWD"`, 시스템 디렉터리만 담은 `PATH`가 모든 렌더 실행에 필수다.

| 게이트 | 명령 | 적용 |
|---|---|---|
| 타입/값 확인 | 스텁 환경에서 `chezmoi execute-template <<<'{{ .agents.omp.settings \| toJson }}'` 출력에 `jq -e '(."completion.notify"\|type=="string") and (."completion.notify"=="off")'` (세 경로 각각) | U1, U2 |
| 렌더 게이트 | 같은 환경에서 `chezmoi execute-template < .chezmoiscripts/70-agents/run_after_config-omp-settings.sh.tmpl` | U1 |
| 알림 표면 전수 확인 | `omp config list --json`의 키 중 `*.notify`로 끝나는 것이 선언한 세 개뿐임을 읽기 전용으로 확인 | U1 |
| 리컨사일러 테스트 | 렌더된 스크립트 경로를 인자로 `.ci/test-omp-settings-reconcile.sh` | U1, U2 |
| 가드 실패 분기 | 선언 값을 `on`이나 불리언으로 바꿔 렌더하면 리컨사일러 테스트가 그 경로를 이름으로 대며 실패한다 | U2 |
| 범위 확인 | `git diff --check`, `git status`, 변경 범위 제한 diff | U1, U2 |
| CI | 푸시 후 `render-dotfiles.yml`과 `ci.yml`을 terminal success까지 감시 | 전체 |

---

## Definition of Done

- R1부터 R12까지 모두 참이다.
- U1과 U2의 모든 테스트 시나리오가 통과한다.
- `git diff`가 `.chezmoidata/agents.yaml`, `.ci/test-omp-settings-reconcile.sh`, `AGENTS.md`, 그리고 이 계획 파일 외의 파일을 보여주지 않는다.
- 시도했다가 버린 코드나 임시 픽스처가 diff에 남아 있지 않다.
- `render-dotfiles.yml`과 `ci.yml`이 terminal success에 도달한다.

---

## Sources / Research

- `.chezmoidata/agents.yaml` — `agents.omp.settings` 선언 블록과 그 소유권 주석; `agents.claude.settings`의 `cleanupPeriodDays`/`env.DISABLE_AUTOUPDATER` 리프 주석 패턴.
- `.chezmoiscripts/70-agents/run_after_config-omp-settings.sh.tmpl` — 평문 heredoc `{{ $settings | toPrettyJson }}` 선언, read-then-compare 수렴, `unknown` 경로의 loud 실패, 경계 있는 omp 읽기.
- `.chezmoitemplates/omp-settings-validate.tmpl` — 경로 문법, 거부 헤드 목록(`plugins`, `marketplaces`, `mcpServers`), null 거부, `modelRoles`/`enabledModels` 특수 처리. 스칼라 값의 타입은 검사하지 않는다.
- `.ci/test-omp-settings-reconcile.sh` — 렌더 표면 needle 루프, 스텁 `omp`, `$calls`/`$state` 픽스처 구조, catalog fail-open 시나리오.
- `.ci/test-claude-settings-reconcile.sh` — `chezmoi execute-template`로 선언을 동적으로 읽는 방식과 `assert_env_types_are_strings`의 실패 분기 픽스처 패턴.
- omp 18.1.15 번들 설정 스키마 — `completion.notify`(enum `["on","off"]`, 기본 `on`), `error.notify`(기본 `off`), `ask.notify`(기본 `on`); 같은 `ui.group: "Notifications"`에 속하지만 알림이 아닌 `ask.timeout`, `recap.enabled`, `recap.idleSeconds`; 데스크톱 전달 경로는 Linux에서 `notify-send` → `gdbus`(`org.freedesktop.Notifications`), macOS에서 `osascript`.
- 이 호스트의 `omp config list --json` — 세 키가 기본값 상태에서도 평평한 점 표기 키로 보고됨(KTD5의 근거).
- `chezmoi execute-template`의 `fromYaml` 확인 — unquoted `off`가 문자열 `"off"`로 파싱됨(KTD2의 근거).
- `AGENTS.md` — 검증 절차, omp 설정/리컨사일러 문단, load-bearing 리프를 이름으로 열거하는 관행.
