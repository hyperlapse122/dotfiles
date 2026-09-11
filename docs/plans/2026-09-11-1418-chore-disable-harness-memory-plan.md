---
title: Disable Built-in Harness Memory - Plan
type: chore
date: 2026-09-11
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
origin: https://github.com/hyperlapse122/dotfiles/issues/474
---

# Disable Built-in Harness Memory - Plan

## Goal Capsule

- **Objective:** 관리 대상 호스트에서 apply를 거친 뒤, 로컬 선언형 스위치를 가진 세 하니스(`claude`, `omp`, `codex`)가 하니스 소유 메모리 저장소를 읽지도 쓰지도 않는다. 스위치가 없는 `agy`는 같은 결과를 공유 지시문으로 겨냥하되 보장 수준이 더 약하다. 에이전트가 받는 상시 지시는 `.chezmoitemplates/agents-instructions.tmpl`과 저장소 보충 지침(`AGENTS.md`) 두 곳에서만 온다.
- **Guarantee boundary:** 이 목표는 user-scope 로컬 메모리에 대해서만 성립한다. Claude Code의 조직/팀 메모리(서버·엔타이틀먼트가 결정), 체크아웃이 자기 `.claude/settings.json`에 넣은 project-scope 설정, `agy`의 계정 수준 Cascade 메모리, 그리고 환경변수 `CLAUDE_CODE_DISABLE_AUTO_MEMORY`가 명시적 거짓 값으로 설정된 호스트는 이 선언의 밖에 있다 (Scope Boundaries).
- **Means:** 토글이 있는 세 하니스(`claude`, `omp`, `codex`)는 각자의 기존 선언 표면(`agents.<harness>.settings`)에 off 값을 선언하고, 로컬 토글이 없는 `agy`는 `.chezmoitemplates/agents-instructions.tmpl`의 공유 본문에 금지 문장을 넣는다 (KTD1, KTD5).
- **Authority:** 이 계획 > 저장소 `AGENTS.md` > 공통 에이전트 지침. 충돌 시 더 좁은 규칙이 우선한다.
- **Execution profile:** 데이터 선언 변경, 지시문 한 문단, 그리고 그 둘을 지키는 회귀 가드. 단위 테스트가 아니라 렌더 게이트와 리컨사일러 테스트가 증거다.
- **Stop conditions:** 렌더 게이트가 새 경로를 거부하거나, `.ci/test-claude-settings-reconcile.sh` / `.ci/test-omp-settings-reconcile.sh` / `.ci/test-codex-settings-reconcile.sh` / `.ci/test-agent-instructions.sh` 중 하나가 실패하면 멈추고 보고한다.
- **Tail ownership:** 호출한 파이프라인이 커밋, 푸시, PR, CI 감시, 머지를 소유한다.

---

## Product Contract

### Summary

관리 대상 하니스 네 개의 내장 메모리 표면을 전수 조사한 결과는 이렇다.

| 하니스 | 메모리 기능 | 로컬 선언형 off 스위치 | 이번 처리 |
|---|---|---|---|
| `claude` (Claude Code 2.1.268) | 있음 — `~/.claude/projects/<slug>/memory/`에 `MEMORY.md` 색인과 사실 파일을 자동으로 쓰고 읽음 | 있음 — `~/.claude/settings.json`의 `autoMemoryEnabled` (boolean), 곁들여 `autoDreamEnabled` | `agents.claude.settings`에 두 리프를 `false`로 선언 |
| `omp` (v18.1.17) | 있음 — `memory.backend`가 고르는 네 가지 백엔드(local / hindsight / mnemopi / sharpshooter)와 `autolearn` 캡처 | 있음 — `memory.backend` (enum, 기본 `off`), `memories.enabled`, `autolearn.enabled`, `autolearn.autoContinue` (모두 boolean, 기본 `false`) | `agents.omp.settings`에 네 리프를 선언 |
| `codex` (rust-v0.154.0) | 있음 — `~/.codex/memories_1.sqlite`와 `memory_summary.md` / `raw_memories.md`를 쓰는 `[memories]` 파이프라인 | 있음 — `features.memories` 기능 플래그 (boolean, 현재 빌드 기본 `false`) | `agents.codex.settings`에 `features.memories`를 `false`로 선언 |
| `agy` (Antigravity 1.2.0) | 있음 — Cascade 메모리(`MemoryToolConfig`, `CortexStepMemory` / `CortexStepRetrieveMemory`) | **없음** — off 스위치인 `UserSettings.disable_auto_generate_memories`와 `MemoryToolConfig.force_disable`은 서버가 내려주는 계정 설정이고, 로컬 `~/.gemini/config/config.json`이 담는 `userSettings`는 다른 proto(`jetbox_state_pb.UserSettings`)라 메모리 필드가 없다 | 지시문 수준 금지 (KTD5) |

세 하니스의 값은 이미 있는 리컨사일러가 매 apply마다 live 설정 파일에 assert한다. `agy`는 assert할 자리가 없으므로, 공유 지시문에 "하니스가 소유한 메모리 저장소에 **쓰지도, 그것을 읽어 지시로 따르지도** 말라"는 문장을 넣어 에이전트 쪽에서 닫는다. 읽기까지 금지하는 것이 핵심이다: 기존 파일은 남기고(R15) `agy`에는 off 스위치가 없으므로, 쓰기만 막으면 `CortexStepRetrieveMemory`가 주입한 낡은 메모리를 에이전트가 계속 지시로 받아들인다. 그 문장은 네 하니스 모두에 같은 글자로 렌더되므로, 토글이 있는 세 하니스에는 이중 방어가 되고 `.ci/test-agent-instructions.sh`의 harness isolation 규칙도 깨지 않는다.

`agy`에 대한 보장은 이 계획에서 가장 약한 고리다. Cascade 메모리 생성은 서버가 돌리는 백그라운드 파이프라인이므로, 클라이언트 쪽 지시문은 에이전트가 그 내용을 **따르는 것**을 막을 뿐 계정에 메모리가 **생성되는 것**을 막지 못한다. 이 문장은 최선 노력 방어이지 apply가 세우는 보장이 아니며, 계정 수준 스위치가 로컬에서 제어 가능해지기 전까지 그대로다.

이미 디스크에 쓰인 메모리 파일은 지우지 않는다. 이 변경은 새 쓰기를 멈추고, 남아 있는 파일을 지시로 따르는 것을 금지할 뿐이다.

보장의 경계는 apply 시점이다. 세 설정 파일 모두 chezmoi 타깃이 아니라 리컨사일 대상이므로, 사용자가 UI로 메모리를 다시 켜면 그 값은 다음 apply까지 살아 있다가 그때 되돌아온다. 선언은 상시 잠금이 아니라 apply마다 다시 세우는 기준선이다.

### Problem Frame

이 저장소는 에이전트가 받는 상시 지시를 **선언**한다. 공통 지시 코어는 `.chezmoitemplates/agents-instructions.tmpl` 하나이고, 네 하니스의 지시 타깃은 모두 그것을 렌더한 결과이며, `.ci/test-agent-instructions.sh`가 네 렌더의 공유 본문이 서로 같은지까지 검사한다.

하니스 내장 메모리는 그 구조 밖에 있는 두 번째 상시 지시 출처다. 에이전트가 세션 중에 스스로 파일을 쓰고, 아무도 리뷰하지 않으며, `chezmoi apply`가 조정하지 않는다. 결과는 네 가지다.

- **선언되지 않는다.** 어떤 템플릿도, 리뷰도, CI 검사도 그 내용을 보지 않는다.
- **조용히 낡는다.** 한 번 적힌 사실이 더 이상 참이 아니게 되어도 계속 로드된다.
- **호스트마다 다르다.** dotfiles가 옮기지 않으므로, 같은 선언을 적용한 두 머신이 다르게 행동한다.
- **통제 밖 sink다.** 선언된 비밀·내용 경계 밖에 있고, `.chezmoidata/agents.yaml`이 `cleanupPeriodDays`에서 이미 기록한 보존 정책 논의 밖에 있다.

조사 시점에 이 호스트의 실제 상태는 이렇다. Claude Code는 `autoMemoryEnabled`가 미선언이고 기본값이 켜짐이라 **실제로 메모리를 쓰고 있으며**, `~/.claude/projects/*/memory/` 디렉터리가 이미 여러 개 만들어져 있다. omp의 네 키와 codex의 `features.memories`는 오늘의 pin된 버전에서 기본값이 off지만, 세 리컨사일러 모두 **미선언 키를 건드리지 않으므로** 선언하지 않으면 UI에서 한 번 켠 값이 다음 apply에도 살아남는다. 선언이 곧 핀이다.

### Key Decisions

- 하니스 소유 메모리는 하니스 자신의 선언형 설정으로 끈다 (session-settled: user-directed — chosen over 메모리 디렉터리를 읽기 전용 빈 트리로 배포하기: 저장소가 이미 `agents.<harness>.settings`라는 리컨사일러와 CI 커버리지를 소유하고 있어, 새 메커니즘은 그 자체로 두 번째 드리프트 출처가 된다). Governs R1–R12.
- 로컬 토글이 없는 하니스는 지시문 수준 금지로 닫는다 (session-settled: user-directed — chosen over 그 하니스의 메모리를 조용히 켜둔 채 두기: 수용 기준이 메모리 기능이 있는 모든 관리 대상 하니스를 요구한다). Governs R13, R14.
- 이미 쓰인 메모리 파일은 그대로 둔다 (session-settled: user-directed — chosen over apply 때 기존 저장소 삭제/정리: 삭제는 파괴적이고 같은 턴의 명시적 사용자 승인이 필요한데 이 실행에는 그 승인이 없다). Governs R15.
- 기본값이 이미 off인 키도 선언한다 (session-settled: user-approved — chosen over 기본값에 맡기고 미선언으로 두기: 세 리컨사일러 모두 미선언 키를 건드리지 않으므로, UI로 켠 값이 다음 apply에 살아남는다. `error.notify`가 같은 이유로 이미 선언되어 있다). 이 결정에는 명시적 예외가 하나 있다 — codex의 `external_agent_memory_import`는 stage가 `under development`라 이름이 흔들리고, codex가 알 수 없는 feature 키를 조용히 무시하므로 선언해도 핀이 조용히 죽는다. 그 예외는 R9가 소유하며, 이 결정은 그것을 지배하지 않는다. Governs R5, R7.

### Requirements

**Claude Code 선언**

- R1. `.chezmoidata/agents.yaml`의 `agents.claude.settings`가 `autoMemoryEnabled`를 JSON boolean `false`로 선언한다.
- R2. 같은 맵이 `autoDreamEnabled`를 JSON boolean `false`로 선언한다.
- R3. 두 리프 바로 위 주석이 (a) 왜 메모리를 끄는지, (b) `autoDreamEnabled`가 메모리 위에 얹히는 백그라운드 통합 패스라 함께 끈다는 것, (c) 되돌리려면 무엇을 바꿔야 하는지, (d) 값은 반드시 JSON boolean이어야 하고 따옴표를 붙이면 Claude Code가 설정 파일 전체를 거부한다는 것, (e) 환경변수 `CLAUDE_CODE_DISABLE_AUTO_MEMORY`가 명시적으로 거짓 값이면 이 리프를 이기고 메모리를 **강제로 켠다**는 것을 기록한다.

**omp 선언**

- R4. `agents.omp.settings`가 `memory.backend`를 문자열 `"off"`로 선언한다.
- R5. 같은 맵이 `memories.enabled`, `autolearn.enabled`, `autolearn.autoContinue`를 각각 boolean `false`로 선언한다.
- R6. 이 네 리프 바로 위 주석이 근거, 이 넷이 pin된 omp 버전에서 확인한 메모리 표면 전부라는 것, 그 확인이 버전에 묶이므로 omp 범프 때 다시 확인해야 한다는 것, `memory.backend`는 enum 토큰이라 따옴표가 표기 관례라는 것, 그리고 `autolearn.enabled`가 메모리 캡처뿐 아니라 `manage_skill` 도구의 게이트이기도 하다는 것(KTD8)을 기록한다.

**Codex 선언**

- R7. `agents.codex.settings`가 `features.memories`를 boolean `false`로 선언한다.
- R8. 그 리프 바로 위 주석이 근거, `[features]`는 `codex features enable/disable`이 쓰는 테이블이라 선언이 그 명령을 되돌린다는 것, codex가 알 수 없는 feature 키를 조용히 무시하므로 키 이름이 바뀌면 이 핀이 조용히 사라진다는 것(따라서 codex 범프 시 `codex features list`로 재확인), 오늘 빌드에서 stage가 `stable`이고 기본값이 `false`라 이 선언은 기본값 뒤집힘에 대한 핀이라는 것을 기록한다.
- R9. `external_agent_memory_import`는 선언하지 않는다. 이것은 "기본값이 이미 off인 키도 선언한다"는 Key Decision의 **명시적 예외**이며, 그 결정은 이 요구사항을 지배하지 않는다. 근거는 두 가지다: stage가 `under development`라 이름이 다음 범프에서 바뀔 수 있고, codex가 알 수 없는 feature 키를 오류 없이 무시하므로 이름이 바뀐 뒤에는 선언이 남아 있어도 아무것도 핀하지 않으면서 핀되어 있다는 착각만 만든다. 그 예외와 근거를 같은 주석이 한 줄로 남긴다.

**렌더 게이트**

- R10. 세 하니스의 새 경로가 각각의 렌더 타임 검증기(`claude-settings-validate.tmpl`, `omp-settings-validate.tmpl`, `codex-settings-validate.tmpl`)를 통과한다. 검증기 자체는 수정하지 않는다.

**리컨사일 동작**

- R11. apply 후 live `~/.claude/settings.json`의 두 키가 JSON boolean `false`가 되고, live `~/.omp/agent/config.yml`의 네 키와 live `~/.codex/config.toml`의 `features.memories`가 선언 값과 같아진다.
- R12. 값이 이미 수렴한 상태에서 리컨사일러를 다시 돌리면 그 경로에 대해 쓰기를 하지 않는다. 기존 선언 경로와 다른 writer가 그 옆에 쓴 미선언 키는 변경 없이 살아남는다.

**agy 지시문 금지**

- R13. `.chezmoitemplates/agents-instructions.tmpl`의 **공유 본문**에, 하니스가 소유한 메모리 저장소에 (a) 쓰지 말고 (b) 거기서 읽어들인 내용을 상시 지시로 받아들이거나 그에 따라 행동하지 말라는 MUST NOT 문장이 들어간다. 쓰기 금지만으로는 부족하다 — 기존 파일이 남고(R15) `agy`에는 off 스위치가 없으므로 읽기 경로가 열린 채 남는다. 네 하니스 렌더 모두에 같은 글자로 나타나므로 harness isolation 규칙을 깨지 않는다.
- R14. `.ci/test-agent-instructions.sh`의 공유 본문 needle 목록이 쓰기 금지 절과 읽기·추종 금지 절을 **각각** needle로 담아, 둘 중 하나가 사라지거나 바뀌면 하니스 이름을 대며 실패한다.

**기존 저장소**

- R15. 이 변경의 어떤 스크립트도 기존 메모리 파일이나 디렉터리를 지우거나 옮기지 않는다. `.chezmoiremove`에도 항목을 추가하지 않는다.

**회귀 방지**

- R16. `.ci/test-claude-settings-reconcile.sh`가 선언에서 boolean으로 읽힌 리프가 **live 파일에서** boolean이 아니면 그 경로 이름과 실제 타입을 대며 실패한다. 이 sweep은 이미 있는 numeric sweep의 거울상이고 같은 한계를 갖는다 — 선언된 타입으로 대상을 고르므로, `agents.yaml`에서 값을 따옴표로 감싸 버린 경우는 이 sweep이 아니라 R17이 잡는다. 손으로 만든 실패 픽스처가 실패 분기를 강제한다.
- R17. 같은 테스트가 선언을 직접 지목해, `autoMemoryEnabled`와 `autoDreamEnabled`가 선언에서 사라지거나, 값이 JSON boolean이 아니거나(따옴표로 감싸인 문자열 포함), `false`가 아니면 이름과 실제 타입을 대며 실패한다. 따옴표 감싸기를 잡는 것은 R16이 아니라 이 요구사항이다.
- R18. `.ci/test-omp-settings-reconcile.sh`가 네 omp 메모리 경로의 렌더 표면 needle과 JSON 타입/값을 확인하고, 미수렴 픽스처에서 `omp config set`이 그 네 경로에 대해 호출되는지, 수렴 픽스처에서는 호출되지 않는지 확인한다.
- R19. `.ci/test-codex-settings-reconcile.sh`가 `features.memories`의 렌더 표면과 JSON 타입(boolean)/값(`false`)을 확인한다.
- R20. `AGENTS.md`가 이 네 하니스의 메모리 처리 — 선언한 일곱 리프, 기본값 뒤집힘에 대한 핀이라는 성격, agy의 지시문 대체책과 그 보장이 설정 핀보다 약하다는 것, `autolearn.enabled`가 `manage_skill`도 게이트한다는 것, 기존 파일을 남긴다는 결정 — 를 기록한다.

### Scope Boundaries

- **기존 메모리 파일은 지우지 않는다.** `~/.claude/projects/*/memory/`, `~/.codex/memories_1.sqlite`, omp의 memories 디렉터리 모두 그대로 둔다. 정리는 사용자의 명시적 승인이 필요한 별개 작업이다.
- **조직/팀 메모리는 범위 밖이다.** Claude Code의 org memory(`CLAUDE_CODE_DISABLE_ORG_MEMORY`, `allow_memory_sync` 엔타이틀먼트, `tengu_haze_glass` 게이트)는 서버와 조직 정책이 켜고 끄며, `settings.json` 리프가 없다. 이번 선언이 닫는 것은 로컬 auto-memory다.
- **환경변수 경로는 추가하지 않는다.** `CLAUDE_CODE_DISABLE_AUTO_MEMORY`는 설정 리프보다 먼저 평가되므로 백업 스위치로 보일 수 있지만, 명시적으로 거짓 값이면 오히려 리프를 이기고 메모리를 켠다. `dot_config/environment.d/`에 아무것도 넣지 않고, 그 함정만 주석에 남긴다. **그래서 Claude Code에 대한 보장은 조건부다:** 이 환경변수가 없거나 참 값일 때만 선언이 실효를 갖는다. 그 변수를 거짓으로 export한 호스트에서는 R1이 통과해도 메모리가 켜져 있고, 그것을 apply 시점에 막는 가드는 이번 범위 밖이다 (Deferred).
- **project-scope Claude 설정은 범위 밖이다.** Claude Code는 project-scope `.claude/settings.json`을 user-scope 위에 둔다. 체크아웃이 자기 `autoMemoryEnabled: true`를 담으면 그 세션에서는 그것이 이긴다. `AGENTS.md`가 이미 기록한 일반적 경계이며 이번 변경이 바꾸지 않는다.
- **효과 상태를 직접 관찰하는 스모크 테스트는 넣지 않는다.** 이 계획의 게이트는 선언·렌더·리컨사일 결과를 본다. 하니스를 실제로 한 번 띄워 메모리 아티팩트가 생기지 않는지 확인하는 검증은 `AGENTS.md`가 금지하는 live `$HOME` 배포를 요구하므로, 별개의 격리 실행 환경을 세우는 작업이다 (Deferred).
- **`autoMemoryDirectory`는 선언하지 않는다.** 저장 위치를 바꾸는 키이지 켜고 끄는 키가 아니다.
- **omp의 `mnemopi.*`, `sharpshooter.*`, `hindsight.*`, `providers.memoryModel`, `memories.*`의 나머지 튜닝 값은 선언하지 않는다.** 모두 `memory.backend`가 고른 백엔드 아래에서만 의미가 있고, 백엔드가 `off`면 실행되지 않는다. 마스터 스위치 하나와 그 위에 독립적으로 얹히는 세 개(`memories.enabled`, `autolearn.enabled`, `autolearn.autoContinue`)만 선언한다.
- **codex `[memories]` 테이블의 세부 키(`generate_memories`, `use_memories`, `dedicated_tools` 등)는 선언하지 않는다.** `features.memories`가 파이프라인 전체의 게이트다.
- **`agents.agy.settings`는 비운 채로 둔다.** 그 키를 읽는 리컨사일러가 없으므로(`.chezmoiscripts/70-agents/`에 agy settings 스크립트가 없다), 값을 넣어도 assert되지 않고 선언이 지켜진다는 착각만 만든다.
- **렌더 타임 검증기 세 개는 수정하지 않는다** (KTD4).
- 호스트별 분기는 하지 않는다. `agents.<harness>.settings`에는 `gate:` 문법이 없고, `AGENTS.md`가 기록하듯 관리 대상 호스트는 모두 같은 운영자 한 사람의 워크스테이션이다.

### Deferred to Follow-Up Work

- `agy`의 계정 수준 `disable_auto_generate_memories`를 선언형으로 뒤집을 방법은 이 저장소에 없다. Antigravity가 로컬 `userSettings`에 그 필드를 받아들이게 되면 그때 `agents.agy.settings`와 그 리컨사일러를 만드는 별개 작업이 된다.
- Claude Code org memory를 로컬에서 끄는 유일한 경로는 환경변수 `CLAUDE_CODE_DISABLE_ORG_MEMORY`다. 이 호스트에서 org memory가 실제로 활성인지 확인된 바 없어 이번 범위에 넣지 않는다.
- `CLAUDE_CODE_DISABLE_AUTO_MEMORY`가 명시적 거짓 값으로 설정된 호스트를 apply 시점에 거부하거나 경고하는 가드. 오늘 어떤 관리 대상 호스트도 그 변수를 export하지 않으므로 현재 신호가 없는 위험이며, 가드를 넣으려면 리컨사일러가 처음으로 환경을 읽어야 한다.
- 하니스를 격리 환경에서 한 번 실행해 메모리 아티팩트가 생기지 않는지 관찰하는 효과 상태 스모크 테스트. 선언 검증이 닿지 못하는 층이지만, live `$HOME`을 쓰지 않는 실행 환경을 먼저 세워야 한다.
- codex `[memories]` 세부 키(`use_memories`, `generate_memories`)를 `features.memories`와 함께 선언하는 이중 방어. feature 키 이름이 바뀌어도 `MemoriesToml`을 직접 묶는다는 장점이 있지만, 그 키들이 feature 게이트가 꺼진 상태에서 어떤 효과를 갖는지 이 계획에서 확인하지 않았다.

---

## Planning Contract

### Key Technical Decisions

- KTD1. **세 하니스는 각자의 기존 선언 표면으로 닫는다.** 세 리컨사일러(`run_after_config-claude-settings.sh.tmpl`, `run_after_config-omp-settings.sh.tmpl`, `run_after_config-codex-settings.sh.tmpl`)가 이미 리프 단위 assert, 렌더 타임 검증, CI 커버리지를 갖고 있다. 메모리 토글은 평범한 스칼라 리프이므로 새 메커니즘이 필요 없다. Governs R1, R2, R4, R5, R7, R11, R12.
- KTD2. **Claude Code의 값은 반드시 JSON boolean이어야 한다.** 설정 스키마에서 `autoMemoryEnabled`와 `autoDreamEnabled`는 `z.boolean().optional()`이다. 문자열 `"false"`는 파싱에서 거부되어 Claude Code가 설정 파일 전체를 버리고 기본값으로 되돌아간다 — `cleanupPeriodDays`의 `z.int()` 함정과 정확히 같은 모양이다. 그 함정은 `assert_declared_present`가 잡지 못한다(같은 잘못된 선언끼리 비교하므로 일치한다). 가드는 **두 층**이고, 각 층이 서로 다른 실패를 잡는다. `.ci/test-claude-settings-reconcile.sh`의 `numeric_leaf_offenders` sweep을 그대로 본뜬 **boolean sweep**은 선언이 boolean인 리프가 live 파일에서 boolean이 아닌 경우를 잡고, 선언된 모든 boolean 리프(`skipDangerousModePermissionPrompt` / `inputNeededNotifEnabled` / `agentPushNotifEnabled` / `remoteControlAtStartup` 포함)를 덮는다. 하지만 이 sweep은 **선언된 타입으로 대상을 고르므로**, `agents.yaml`에서 값을 `"false"`로 따옴표 감싸 버린 경우에는 아무것도 고르지 않아 조용히 통과한다 — numeric sweep이 `cleanupPeriodDays`에 대해 갖는 것과 똑같은 구멍이다. 그래서 `cleanup_period_offender`와 같은 모양의 **선언 직접 지목 검사**를 두 메모리 키에 대해 따로 둔다. sweep은 live 드리프트를, 지목 검사는 잘못 쓴 선언을 잡는다. Governs R1, R2, R16, R17.
- KTD3. **가짜 백업 스위치를 넣지 않는다.** Claude Code의 auto-memory 게이트는 `CLAUDE_CODE_DISABLE_AUTO_MEMORY`를 먼저 본다: 참 값이면 끄고, **명시적 거짓 값이면 설정 리프를 읽지 않고 켠다**. 그래서 이 환경변수는 설정 리프의 보강이 아니라 그것을 무력화할 수 있는 상위 경로다. `DISABLE_AUTOUPDATER`가 Linux와 macOS 양쪽에 이중 선언된 것과 달리, 이 값은 설정 리프 하나로만 선언하고 함정을 주석에 남긴다. Governs R3.
- KTD4. **렌더 타임 검증기 세 개는 그대로 둔다.** 새 경로는 일곱 개다 — Claude 두 개(`autoMemoryEnabled`, `autoDreamEnabled`), omp 네 개(`memory.backend`, `memories.enabled`, `autolearn.enabled`, `autolearn.autoContinue`), Codex 한 개(`features.memories`). 일곱 모두 세 검증기의 경로 문법(`^[A-Za-z][A-Za-z0-9_-]*([.][A-Za-z][A-Za-z0-9_-]*)*$`)을 통과하고, 헤드(`autoMemoryEnabled`, `autoDreamEnabled`, `memory`, `memories`, `autolearn`, `features`)는 어느 거부 목록에도 없으며, 값은 스칼라이고 security allowlist 대상도 아니다. 검증기 변경은 불필요하다. Governs R10.
- KTD5. **`agy`는 지시문으로만 닫히고, 그 문장은 공유 본문에 둔다.** agy의 off 스위치는 서버가 내려주는 `codeium_common_pb.UserSettings.disable_auto_generate_memories`와 `MemoryToolConfig.force_disable`이다. 로컬 `~/.gemini/config/config.json`의 `userSettings`는 `jetbox_state_pb.UserSettings`로 매핑되고 그 메시지에는 메모리 필드가 없다 — 이 호스트의 바이너리에서 필드를 전수 확인했다. 따라서 선언형 표면이 존재하지 않는다. 금지 문장을 agy 전용 `This harness is ` 문단에 넣으면 그 문단의 whole-file 픽스처(`.ci/fixtures/agent-instructions/harness-is-agy.txt`)를 함께 고쳐야 하고 규칙이 한 하니스에 갇힌다. 공유 본문에 넣으면 네 렌더에 같은 글자로 나타나 peer diff를 통과하고, 토글이 있는 세 하니스에는 이중 방어가 된다.

  이 대체책의 한계를 명시한다. Cascade 메모리 생성은 `CortexStepMemory`를 포함한 서버 쪽 파이프라인이 돌리므로, 클라이언트 지시문은 계정에 메모리가 **생성되는 것**을 막지 못한다. 그것이 읽기까지 금지해야 하는 이유다 — 생성을 막을 수 없다면 남은 지렛대는 `CortexStepRetrieveMemory`가 주입한 내용을 에이전트가 지시로 받아들이지 않게 하는 것뿐이다. 이 문장은 최선 노력 방어이며, apply가 세우는 보장은 아니다. Governs R13, R14.
- KTD6. **omp은 마스터 스위치 하나로 부족하다.** `memory.backend: "off"`는 백엔드 파이프라인을 닫지만, `memories.enabled`(별도 rollout 요약 파이프라인)와 `autolearn.enabled`/`autolearn.autoContinue`(턴 종료 시 lesson 캡처)는 그와 독립된 boolean이다. 오늘의 pin된 빌드에서 넷 다 기본값이 off지만 미선언 키는 다음 apply에 되돌아오지 않으므로, 넷을 모두 선언한다. 이 호스트의 `omp config list --json`이 네 키를 모두 평평한 점 표기 키로 보고하므로 리컨사일러의 `unknown` 분기는 발동하지 않는다. Governs R4, R5, R6, R11, R12.
- KTD7. **codex의 게이트는 `[memories]` 테이블이 아니라 feature 플래그다.** `codex features list`가 `memories`를 stage `stable`로 보고하고, `-c features.memories=true|false`로 실제 상태가 뒤집히는 것을 확인했다. 오늘의 빌드에서 기본값은 `false`이고 `~/.codex/config.toml`에는 `[features]` 테이블이 아예 없다 — 즉 지금은 기본값에 기대고 있다. stable feature의 기본값은 버전 범프에서 뒤집힐 수 있으므로 선언이 필요하다. 다만 codex는 알 수 없는 feature 키를 오류 없이 무시하므로(`-c features.bogus_nonexistent=true`로 확인), 이름이 바뀌면 이 핀은 조용히 죽는다 — 그 사실을 주석에 남기는 것이 유일한 방어다. 같은 이유로 `external_agent_memory_import`는 선언하지 않는다(R9): under development 단계의 이름은 더 잘 흔들리고, 죽은 핀은 없는 핀보다 나쁘다. Governs R7, R8, R9.
- KTD8. **`autolearn.enabled`는 메모리 전용 키가 아니다.** pin된 omp v18.1.17에서 `manage_skill` 도구의 게이트는 `autolearn.enabled` 단독이며 `memory.backend`와 무관하다(`A === "manage_skill"`은 `settings.get("autolearn.enabled")`만 본다; `learn`은 여기에 더해 백엔드가 `hindsight`/`mnemopi`/`local`일 것을 요구한다). 이 키의 기본값이 이미 `false`이므로 선언은 실효 동작을 바꾸지 않는다 — `manage_skill`은 오늘도 사용할 수 없다. 그래도 이 결합은 기록해야 한다: 누군가 나중에 스킬 관리를 쓰려고 이 키를 켜면 그와 동시에 메모리 캡처가 다시 열리기 때문이다. 이 계획은 그 사실을 리프 주석(R6)과 `AGENTS.md`(R20)에 남기고, 스킬 관리를 되찾는 방법은 별개 작업으로 둔다. Governs R5, R6, R20.

### System-Wide Impact

이 변경 뒤 `claude`, `omp`, `codex`는 세션 중에 사실을 적어두고 다음 세션에 자동으로 다시 읽지 않는다. `agy`에서는 같은 결과를 지시문으로만 겨냥하므로, 계정 쪽 메모리는 계속 생성될 수 있고 에이전트가 그것을 따르지 않는 것이 보장의 전부다. 에이전트가 세션 사이에 지식을 옮기려면 저장소가 이미 소유한 경로 — 지시문 템플릿, 저장소 `AGENTS.md`, `docs/plans/`, 커밋된 학습 기록 — 를 써야 한다. 이것이 의도된 결과다: 지식은 축적되는 것이 아니라 선언되고 리뷰된다.

대가는 분명하다. 사용자가 세션 중에 "이걸 기억해"라고 말해도 하니스가 스스로 저장할 자리가 없다. 그런 사실은 리뷰를 거쳐 저장소에 들어가야 하며, 그것이 이 변경이 사는 목적이다.

omp에서는 한 가지 결합이 따라온다. `autolearn.enabled: false`는 `manage_skill` 도구도 함께 닫는다(KTD8). 그 키의 기본값이 이미 `false`라 오늘 쓸 수 있던 것을 빼앗지는 않지만, 이 선언 이후에는 스킬 관리를 되찾는 일이 곧 메모리 캡처를 다시 여는 일이 된다.

리컨사일러는 선언 경로 단위로 assert하므로, 새로 추가되는 일곱 경로는 기존 선언과 서로 독립적이다. 한 경로의 assert 실패는 그 경로만 실패시킨다.

### Risks & Dependencies

- **하니스 버전 범프.** 키 이름이나 타입이 바뀌면 omp은 리컨사일러의 `unknown` 분기가 이름을 대며 apply를 실패시키고, Claude Code는 미지의 키를 무시하며(설정 스키마가 공개되지 않아 오타가 성공으로 보고된다는 `AGENTS.md`의 기존 서술 그대로), codex는 알 수 없는 feature 키를 조용히 무시한다. 세 하니스 모두 `.chezmoidata/releases.json`으로 pin되어 있어 변화는 범프 시점에만 들어오고, 각 리프의 주석이 그때 무엇을 재확인해야 하는지 지시한다.
- **`agy`의 보장 수준이 다르다.** 지시문 금지는 모델의 준수에 기대므로 설정 핀보다 약하다. 이것은 이 계획의 결함이 아니라 agy가 로컬 선언형 표면을 제공하지 않는다는 사실의 반영이며, `AGENTS.md`에 그렇게 기록한다.
- **공동 writer.** 세 설정 파일 모두 하니스 자신이 UI로 쓴다. 세 리컨사일러의 read-then-compare와 리프 단위 assert가 이미 이를 처리한다.
- **Claude Code의 project-scope 설정.** Claude Code는 project-scope 설정을 user-scope 위에 둔다. 체크아웃이 자기 `.claude/settings.json`에 `autoMemoryEnabled: true`를 담으면 그것이 이긴다 — `AGENTS.md`가 이미 기록한 일반적 경계이며 이번 변경이 바꾸지 않는다.

---

## Implementation Units

### U1. 세 하니스의 메모리 토글 선언

- **Goal:** `agents.claude.settings`, `agents.omp.settings`, `agents.codex.settings`에 메모리 off 리프를 선언하고, 각 리프 위에 근거·함정·되돌리는 법을 주석으로 남긴다.
- **Requirements:** R1, R2, R3, R4, R5, R6, R7, R8, R9, R10, R15 (KTD1, KTD2, KTD3, KTD4, KTD6, KTD7)
- **Dependencies:** 없음
- **Files:**
  - `.chezmoidata/agents.yaml` — 세 `settings` 맵에 리프 추가와 그 위 주석
- **Approach:**
  1. `agents.claude.settings`에 `autoMemoryEnabled: false`와 `autoDreamEnabled: false`를 추가한다. 기존 비-`env` 스칼라가 모여 있는 구역, `cleanupPeriodDays` 다음이자 `env.DISABLE_AUTOUPDATER` 앞에 둔다.
  2. 그 두 리프 **바로 위**에 주석을 붙인다 — `cleanupPeriodDays`와 `env.DISABLE_AUTOUPDATER`가 이미 쓰는 배치다. 담을 것: 이 저장소는 상시 지시를 선언하지 축적하지 않으며 하니스 소유 메모리는 리뷰도 reconcile도 받지 않는 두 번째 출처라는 것; `autoDreamEnabled`는 메모리 위에 얹히는 백그라운드 통합 패스라 함께 끈다는 것; 두 값은 `z.boolean()`으로 파싱되므로 따옴표를 붙이면 Claude Code가 설정 파일 전체를 거부하고 기본값으로 돌아간다는 것과 그것을 잡는 가드가 `.ci/test-claude-settings-reconcile.sh`에 있다는 것; `CLAUDE_CODE_DISABLE_AUTO_MEMORY`가 명시적 거짓 값일 때 이 리프를 이기고 메모리를 켜므로 그 환경변수를 백업 스위치로 쓰지 말라는 것; 되돌리려면 이 두 줄을 지우거나 `true`로 바꾸고 apply 한 번이면 된다는 것; 기존 `~/.claude/projects/*/memory/` 파일은 남는다는 것.
  3. `agents.omp.settings`에 `memory.backend: "off"`, `memories.enabled: false`, `autolearn.enabled: false`, `autolearn.autoContinue: false`를 추가한다. 알림 리프 다음이자 `astGrep.enabled` 앞, 비모델 스칼라 구역에 둔다.
  4. 그 네 리프 위 주석에: 근거; `memory.backend`는 백엔드 선택 enum이고 나머지 셋은 그와 독립된 boolean이라 마스터 스위치 하나로 부족하다는 것; 넷 다 pin된 버전에서 기본값이 off지만 미선언 키는 다음 apply에 되돌아오지 않으므로 선언이 곧 핀이라는 것(`error.notify`와 같은 이유); 이 열거가 pin된 omp 버전에 묶이므로 `.chezmoidata/releases.json`의 omp 범프 때 `omp config list --json`으로 새 메모리 키를 재확인해야 한다는 것; `"off"`는 불리언이 아니라 enum 토큰이라 따옴표가 표기 관례라는 것.
  5. `agents.codex.settings`에 `features.memories: false`를 추가한다.
  6. 그 리프 위 주석에: 근거; `[features]`는 `codex features enable/disable`이 쓰는 테이블이므로 이 선언이 그 명령을 다음 apply에 되돌린다는 것; 오늘 빌드에서 stage가 `stable`이고 기본값이 `false`이며 live `config.toml`에 `[features]` 테이블이 아예 없으므로 이 선언은 기본값 뒤집힘에 대한 핀이라는 것; codex가 알 수 없는 feature 키를 조용히 무시하므로 키 이름이 바뀌면 이 핀이 조용히 죽고, 따라서 codex 범프 때 `codex features list`로 `memories` 행이 남아 있는지 확인해야 한다는 것; `external_agent_memory_import`를 선언하지 않은 이유(under development 단계라 이름이 흔들리고, 사라진 키는 조용히 무시되어 핀이 조용히 죽는다).
  7. `agents.agy.settings`는 `{}` 그대로 둔다. 그 위에 한 줄 주석으로 왜 비어 있는지 — agy는 메모리 기능을 갖고 있지만 off 스위치가 서버 쪽 계정 설정이고 로컬 `~/.gemini/config/config.json`의 `userSettings`에는 그 필드가 없으며, 이 키를 읽는 리컨사일러도 없으므로 값을 넣어도 assert되지 않는다 — 를 남기고, 대체책이 `.chezmoitemplates/agents-instructions.tmpl`의 금지 문장임을 가리킨다.
- **Execution note:** 설정 선언 변경이다. 단위 테스트 대신 렌더 게이트와 리컨사일러 테스트로 증명한다. live `$HOME`에는 배포하지 않는다.
- **Patterns to follow:** 같은 파일의 `cleanupPeriodDays` 항목 — 리프 옆 주석에 근거, 타입 함정, 되돌리는 법, 버전 범프 시 재확인 지시를 함께 남기는 방식. omp 알림 세 리프의 "declaring is what pins" 서술.
- **Test scenarios:**
  - 선언 타입 (claude): 스텁 `op`, 빈 config, 임시 destination, `--source "$PWD"` 환경에서 `chezmoi execute-template <<<'{{ .agents.claude.settings | toJson }}'`의 출력에 대해 `jq -e '(.autoMemoryEnabled|type=="boolean") and (.autoMemoryEnabled==false)'`가 성공한다. `autoDreamEnabled`도 같다.
  - 선언 타입 (omp): 같은 방식으로 `."memory.backend"`가 문자열 `"off"`, `."memories.enabled"` / `."autolearn.enabled"` / `."autolearn.autoContinue"`가 boolean `false`다.
  - 선언 타입 (codex): 같은 방식으로 `."features.memories"`가 boolean `false`다.
  - 렌더 게이트: 세 리컨사일러 템플릿이 모두 성공적으로 렌더된다 — 즉 세 검증기가 새 경로를 거부하지 않는다 (R10).
  - 표면 전수 확인 (omp): `omp config list --json`의 키 중 이름에 `memor` 또는 `autolearn`이 들어가면서 마스터 스위치 성격인 것이 선언한 넷뿐임을 읽기 전용으로 확인한다.
  - 표면 전수 확인 (codex): `codex features list`에서 이름에 `memor`가 들어가는 행이 `memories`와 `external_agent_memory_import` 둘뿐임을 확인하고, 후자를 선언하지 않은 이유가 주석에 남아 있다 (R9).
  - 기존 저장소 무변경: `git diff`가 `.chezmoiremove`를 건드리지 않고, 어떤 스크립트도 메모리 경로를 지우지 않는다 (R15).
- **Verification:** 렌더 게이트와 세 선언 타입 확인이 통과하고, 두 전수 확인 결과가 기록된다. 리컨사일 동작(R11·R12)의 증거는 U3이 추가하는 픽스처 실행이 소유한다.

### U2. agy를 위한 공유 지시문 금지

- **Goal:** 로컬 토글이 없는 하니스에서도 에이전트가 하니스 소유 메모리 저장소에 쓰지 않고, 거기서 읽어들인 내용을 상시 지시로 따르지도 않도록, 공유 지시 코어에 MUST NOT 문장을 넣는다.
- **Requirements:** R13, R14 (KTD5)
- **Dependencies:** 없음
- **Files:**
  - `.chezmoitemplates/agents-instructions.tmpl` — 공유 본문에 금지 문장
  - `.ci/test-agent-instructions.sh` — 공유 본문 needle 목록에 그 문장 추가
- **Approach:**
  1. `.chezmoitemplates/agents-instructions.tmpl`의 **공유 본문**에 금지 문장을 넣는다. 자리는 "Skills and instruction precedence" 절 — 이 규칙이 다루는 것이 정확히 "상시 지시가 어디에서 오는가"이기 때문이다. 하니스 조건 분기(`.harness`) 안에 넣지 않는다: 네 렌더가 같아야 peer diff를 통과한다 (KTD5).
  2. 문단은 **두 개의 MUST NOT**을 담는다. (a) 하니스가 자체 메모리 저장소(하니스가 소유하고, 에이전트가 스스로 쓰고, 세션 시작에 다시 로드하는 것)를 제공하더라도 **거기에 쓰지 말 것**. (b) 그 저장소에서 읽힌 내용을 **상시 지시로 받아들이거나 그에 따라 행동하지 말 것** — 하니스가 세션 시작에 주입하더라도 마찬가지다. (b)가 없으면 규칙은 절반만 닫힌다: 기존 파일은 남고(R15) `agy`의 계정 메모리는 서버가 계속 만들므로, 읽기 경로는 쓰기를 막아도 열려 있다.
  3. 같은 문단이 함께 담을 것: 이 파일과 저장소 보충 지침(`AGENTS.md`)이 상시 지시의 유일한 출처라는 것; 세션 밖으로 옮겨야 할 사실은 리뷰를 거쳐 저장소에 넣을 것; 기존에 쓰인 메모리를 지우거나 옮기지는 말 것(삭제는 파괴적이고 사용자 승인이 필요하다). 하니스의 자동 리마인더가 메모리에 쓰라고 지시하더라도 이 규칙이 이긴다는 것을 명시한다 — 이 파일의 기존 composition 규칙이 이미 harness default와 automatic reminder를 이 파일 아래에 두므로, 그 규칙을 인용하는 형태로 쓴다. 이 금지를 "active conversation까지 구속하는" 상시 금지 목록(secrets·destructive-action·dispatch-routing)에 넣지는 않는다: 사용자가 세션 중에 무엇을 기록해 달라고 요청하는 것 자체는 막을 일이 아니고, 이 규칙이 정하는 것은 그 기록이 **어디로 가는가**다.
  4. 문장은 기존 문체를 따른다: RFC 2119 용어를 문자 그대로, ASD-STE100 원칙대로 짧은 문장, 한 문장에 한 지시.
  5. `.ci/test-agent-instructions.sh`의 `NEEDLES` heredoc(공유 본문 needle 목록)에 **두 절을 각각** needle로 추가한다 — 쓰기 금지 절 하나, 읽기·추종 금지 절 하나. 하나만 넣으면 나머지 절이 조용히 사라질 수 있다. needle은 공유 본문 전체에 대해 `grep -F`로 검사되므로 네 하니스 모두에서 발견되어야 한다.
- **Execution note:** 지시문 텍스트 변경이다. `.ci/test-agent-instructions.sh`가 네 하니스 × 두 OS 분기 렌더를 모두 비교하므로, 문장이 한 하니스에만 들어가면 그 테스트가 잡는다.
- **Patterns to follow:** 같은 파일의 "Skills and instruction precedence" 절과 "File edits and native tools" 절 — MUST NOT을 문자 그대로 쓰고, 왜 그런지를 한 문장으로 덧붙이는 형식. `.ci/test-agent-instructions.sh`의 `NEEDLES` 목록에 이미 들어 있는 행들.
- **Test scenarios:**
  - `.ci/test-agent-instructions.sh`가 전체 통과한다 — 네 하니스 렌더의 공유 본문이 여전히 서로 같고, 새 needle 두 개가 모두 네 하니스에서 발견된다.
  - 문장을 하니스 분기 안으로 옮기면 같은 테스트가 peer diff 단계에서 실패한다.
  - 쓰기 금지 절을 지우면 그 needle이 하니스 이름과 잃어버린 규칙을 대며 실패한다.
  - **읽기·추종 금지 절만** 지우면 쓰기 금지 needle은 여전히 통과하지만 읽기 needle이 실패한다 — 두 절을 따로 needle로 둔 이유가 이것이다.
  - 네 지시 타깃(`dot_claude/`, `dot_gemini/`, `dot_codex/`, `dot_omp/private_agent/`) 렌더 모두에 두 절이 각각 정확히 한 번 나타난다.
- **Verification:** `.ci/test-agent-instructions.sh`가 통과하고, 문장을 임시로 지운 렌더에서 그 테스트가 이름을 대며 실패한다.

### U3. 선언을 지키는 상시 CI 가드

- **Goal:** 나중에 누가 일곱 경로(Claude 둘, omp 넷, Codex 하나) 중 하나를 지우거나 값을 뒤집거나 잘못된 JSON 타입으로 만들면 CI가 그 경로 이름을 대며 실패하게 하고, 리컨사일 동작(R11·R12)의 증거를 픽스처 실행으로 확보한다.
- **Requirements:** R11, R12, R16, R17, R18, R19 (KTD2, KTD6, KTD7)
- **Dependencies:** U1
- **Files:**
  - `.ci/test-claude-settings-reconcile.sh` — boolean 리프 sweep과 그 실패 픽스처, 두 메모리 경로 확인
  - `.ci/test-omp-settings-reconcile.sh` — 렌더 표면 needle 넷, 타입/값 sweep, 미수렴·수렴 픽스처
  - `.ci/test-codex-settings-reconcile.sh` — 렌더 표면 needle, 타입/값 확인
- **Approach:**
  1. **claude — 지목 검사가 먼저다.** 기존 `cleanup_period_offender`와 같은 형태로, 선언 자체를 이름으로 지목하는 `memory_leaf_offender`를 넣는다: `autoMemoryEnabled`와 `autoDreamEnabled`가 선언에 존재하는지, 값의 JSON 타입이 `boolean`인지, 값이 `false`인지. 선언에서 사라지거나, 따옴표로 감싸여 문자열이 되거나, `true`로 뒤집히면 경로 이름과 실제 타입을 대며 실패한다 (R17). **따옴표 감싸기를 잡는 것은 이 검사뿐이다** — 아래 sweep은 선언된 타입으로 대상을 고르므로 문자열 선언을 아예 선택하지 않는다 (KTD2).
  2. 그 다음 기존 `numeric_leaf_offenders` / `assert_numeric_leaves` 쌍을 그대로 본뜬 `boolean_leaf_offenders` / `assert_boolean_leaves`를 추가한다. 선언에서 값 타입이 `boolean`인 리프를 골라, live 파일의 같은 경로가 boolean이 아니면 경로 이름을 출력한다 — 즉 이 sweep이 담당하는 것은 선언이 아니라 **live 파일의 타입 드리프트**다. `getpath`는 스칼라 조상에서 raise하므로 기존과 같이 `try`로 감싼다. 존재하지 않는 리프는 `assert_declared_present`의 몫이므로 이 sweep이 보지 않는다.
  3. 두 가드 각각에 손으로 만든 실패 픽스처를 넣는다. 지목 검사: 선언이 `{"autoMemoryEnabled":"false"}`(문자열)일 때, `true`일 때, 키가 없을 때 각각 이름을 대며 실패하고, `false`일 때 통과한다. sweep: live 파일이 `{"autoMemoryEnabled":"false"}`일 때 플래그되고, `{"autoMemoryEnabled":false}`일 때 통과하며, 그 키가 없는 파일은 플래그되지 않는다. 오늘의 올바른 선언만 돌리면 실패 분기가 CI에서 한 번도 실행되지 않아 가드가 조용히 죽는다 — 기존 `cleanupPeriodDays` 픽스처 3종과 같은 이유다.
  4. 기존 드리프트 픽스처(`$scratch/settings.json`)에 `"autoMemoryEnabled": true`를 넣어, 리컨사일러 실행 후 `false`로 수렴하는지 확인한다 (R11). 이미 `false`인 픽스처에서는 파일이 바이트 동일하게 남는지 기존 수렴 검사로 확인한다 (R12).
  5. **omp:** 파일 상단의 렌더 표면 needle 목록에 `"memory.backend": "off"`, `"memories.enabled": false`, `"autolearn.enabled": false`, `"autolearn.autoContinue": false` 넷을 더한다. 이 리컨사일러는 선언을 평문 heredoc JSON으로 렌더하므로 needle grep이 실제 값을 본다.
  6. 기존 `notify_offenders`를 본뜬 타입/값 검사를 더한다: `memory.backend`가 문자열 `off`인지, 나머지 셋이 boolean `false`인지. 실패 분기를 손으로 만든 픽스처로 강제한다 — `memory.backend`가 `"local"`인 픽스처, `memories.enabled`가 문자열 `"false"`인 픽스처, 경로가 아예 없는 픽스처.
  7. 네 키가 켜진 live 픽스처를 추가하고, 리컨사일러가 그 네 경로에 대해 `omp config set`을 호출하는지 기존 `$state` / `$calls` 방식으로 확인한다. 이미 수렴한 픽스처에서는 그 네 경로에 대한 줄이 하나도 없어야 한다 (R12). 실행 후 픽스처 config의 네 값과, 기존 선언 경로 및 미선언 형제 키가 그대로인지도 확인한다.
  8. **codex:** 렌더 표면에서 `features.memories`가 값 `false`로 나타나는지 확인하고, `chezmoi execute-template <<<'{{ .agents.codex.settings | toJson }}'` 출력에서 `."features.memories"`의 타입이 `boolean`이고 값이 `false`인지 확인한다. 실패 분기는 문자열 `"false"` 픽스처와 `true` 픽스처로 강제한다. 기존 드리프트 픽스처에 `[features] memories = true`를 넣어 수렴을 확인하고, Codex 소유 테이블(`projects`, `hooks`, `plugins`, `marketplaces`)과 미선언 키가 살아남는지 기존 검사로 확인한다.
- **Execution note:** 이 가드의 가치는 실패할 때에만 나온다. 먼저 잘못된 타입 픽스처로 실패하는 것을 보고, 그다음 통과 경로를 붙인다.
- **Patterns to follow:** `.ci/test-claude-settings-reconcile.sh`의 `numeric_leaf_offenders` / `assert_numeric_leaves`와 그 실패 픽스처 3종, `cleanup_period_offender`의 선언 직접 지목 방식. `.ci/test-omp-settings-reconcile.sh`의 needle 루프, `notify_offenders`, `reset()` / `$calls` / `$state` 픽스처 구조. `.ci/test-codex-settings-reconcile.sh`의 기존 리프 확인.
- **Test scenarios:**
  - claude: 선언이 `autoMemoryEnabled: "false"`(따옴표 감싼 문자열)인 데이터에서 **지목 검사**가 그 경로 이름과 실제 타입(`string`)을 대며 실패하고, 같은 데이터에서 boolean sweep은 아무것도 플래그하지 않는다 — 두 가드의 역할 분담을 이 한 시나리오가 증명한다.
  - claude: `autoMemoryEnabled`를 선언하지 않은 데이터에서 지목 검사가 그 경로 이름을 대며 실패한다.
  - claude: 선언 값을 `true`로 바꾼 데이터에서 지목 검사가 실패한다.
  - claude: live 파일이 `{"autoMemoryEnabled":"false"}`인 픽스처에서 boolean sweep이 그 경로를 이름과 실제 타입(`string`)과 함께 플래그한다.
  - claude: live 파일이 `{"autoMemoryEnabled":false}`인 픽스처에서 boolean sweep이 아무것도 플래그하지 않는다.
  - claude: `"autoMemoryEnabled": true`인 live 픽스처 실행 후 값이 `false`가 되고, 다른 writer의 키(`hooks`, `enabledPlugins`, `extraKnownMarketplaces`)와 미선언 키(`theme`, `editorMode`)가 그대로다.
  - claude: 이미 수렴한 픽스처를 다시 실행하면 파일이 바이트 동일하다.
  - omp: 네 needle이 모두 렌더 표면에서 발견된다. 하나를 선언에서 지우면 그 needle이 이름을 대며 실패한다.
  - omp: `memory.backend`가 `"local"`인 픽스처, `memories.enabled`가 문자열인 픽스처, 경로가 없는 픽스처에서 타입/값 검사가 각각 이름을 대며 실패한다.
  - omp: 네 키가 켜진 live 픽스처 실행 후 `$state`에 네 경로 각각에 대한 `config set` 줄이 정확히 한 줄씩 남고, 실행 후 네 값이 모두 off/false다.
  - omp: 네 키가 이미 수렴한 픽스처 실행 후 그 네 경로에 대한 줄이 하나도 없다.
  - codex: 렌더 표면에 `features.memories`가 값 `false`로 나타나고, 선언 타입이 boolean이다.
  - codex: 문자열 `"false"` 픽스처와 `true` 픽스처에서 타입/값 검사가 이름을 대며 실패한다.
  - codex: `[features] memories = true`인 live 픽스처 실행 후 `false`로 수렴하고, Codex 소유 테이블이 살아남는다.
- **Verification:** 세 리컨사일러 테스트가 모두 통과하고, 선언 값을 일시적으로 뒤집거나 잘못된 타입으로 바꿔 렌더하면 해당 테스트가 경로 이름을 대며 실패한다.

### U4. AGENTS.md 기록

- **Goal:** 저장소 계약 문서가 네 하니스의 메모리 처리와 그 근거를 기록해, 다음 편집이 실수로 되살리지 않게 한다.
- **Requirements:** R20
- **Dependencies:** U1, U2
- **Files:**
  - `AGENTS.md` — Claude/Codex 설정 assertion 문단, omp 모델 배치 문단, 그리고 지시 타깃 문단
- **Approach:**
  1. Claude/Codex assertion 문단(현재 "Antigravity declares no settings leaves"로 끝나는 문단)에 메모리 핀을 더한다: Claude Code의 `autoMemoryEnabled` / `autoDreamEnabled`, Codex의 `features.memories`, 각각이 기본값 뒤집힘에 대한 핀이라는 성격, Claude 값이 JSON boolean이어야 한다는 것과 그 가드의 위치, `CLAUDE_CODE_DISABLE_AUTO_MEMORY`를 백업 스위치로 쓰지 않는 이유.
  2. 같은 문단의 Antigravity 문장을 확장한다: agy는 메모리 기능을 갖고 있지만 off 스위치가 서버 쪽 계정 설정이라 선언할 자리가 없고, 그래서 지시문 수준 금지로 대체했으며, 그 금지는 쓰기와 읽기·추종을 함께 덮되 서버가 계정에 메모리를 **생성**하는 것은 막지 못하므로 보장 수준이 설정 핀보다 약하다는 것.
  3. omp 모델 배치 문단(비모델 예외를 열거하는 문단)에 메모리 핀 네 개를 더한다: `memory.backend`, `memories.enabled`, `autolearn.enabled`, `autolearn.autoContinue`, 마스터 스위치 하나로 부족한 이유, 버전 범프 시 재확인 의무, 그리고 `autolearn.enabled`가 `manage_skill` 도구의 게이트이기도 하다는 것 — 기본값이 이미 `false`라 잃는 것은 없지만, 나중에 스킬 관리를 켜는 것이 곧 메모리 캡처를 켜는 것이라는 결합.
  4. 기존 메모리 파일을 지우지 않는다는 결정을 한 문장으로 남긴다 — 이번 변경이 새 쓰기만 멈춘다는 것과, 정리는 사용자 승인이 필요한 별개 작업이라는 것.
  5. 지시 타깃 문단에 새 공유 규칙이 있다는 사실은 따로 쓰지 않는다. 그 문단은 메커니즘을 설명하지 개별 규칙을 열거하지 않으며, `.ci/test-agent-instructions.sh`의 needle이 이미 그 규칙의 소유자다.
- **Execution note:** 문서 변경이다. 기존 문단의 문체(한 문단 안에 메커니즘·근거·대가를 함께 담는 긴 산문)를 따른다.
- **Patterns to follow:** `AGENTS.md`의 `cleanupPeriodDays` 서술 — 무엇을 핀했는지, 왜인지, 대가가 무엇인지, 그 가드가 어디 있는지를 한 문장 안에 담는 방식.
- **Test scenarios:**
  - `AGENTS.md`가 일곱 선언 경로를 모두 이름으로 언급한다.
  - `AGENTS.md`가 agy의 대체책과 그 보장 수준 차이를 언급한다.
  - `AGENTS.md`가 `autolearn.enabled`와 `manage_skill`의 결합을 언급한다.
  - `AGENTS.md`가 기존 메모리 파일을 남긴다는 결정을 언급한다.
  - `.ci/test-ci-wiring.sh`를 포함한 기존 CI 스크립트가 여전히 통과한다.
- **Verification:** 위 시나리오를 모두 diff에서 확인한다.

---

## Verification Contract

`AGENTS.md`의 검증 규칙을 그대로 따른다. live `$HOME`에는 절대 배포하지 않는다. 스크래치 디렉터리, 스텁 `op`, 빈 config, 임시 destination, `--source "$PWD"`, 시스템 디렉터리만 담은 `PATH`가 모든 렌더 실행에 필수다.

| 게이트 | 명령 | 적용 |
|---|---|---|
| 선언 타입 (claude) | 스텁 환경에서 `chezmoi execute-template <<<'{{ .agents.claude.settings \| toJson }}'` 출력에 `jq -e '(.autoMemoryEnabled\|type=="boolean") and (.autoMemoryEnabled==false)'` (두 경로 각각) | U1, U3 |
| 선언 타입 (omp) | 같은 방식으로 `."memory.backend"`가 문자열 `"off"`, 나머지 셋이 boolean `false` | U1, U3 |
| 선언 타입 (codex) | 같은 방식으로 `."features.memories"`가 boolean `false` | U1, U3 |
| 렌더 게이트 | 같은 환경에서 세 리컨사일러 템플릿을 `chezmoi execute-template`로 렌더 | U1 |
| 표면 전수 확인 | `omp config list --json`과 `codex features list`를 읽기 전용으로 열거해 마스터 스위치를 확인 | U1 |
| 경로 수 확인 | 선언에 더해진 새 경로가 정확히 일곱 개(Claude 2 + omp 4 + Codex 1)임을 diff에서 센다 | U1, U3, U4 |
| 지시문 테스트 | `.ci/test-agent-instructions.sh` — 쓰기 금지 needle과 읽기·추종 금지 needle이 **각각** 네 하니스에서 발견된다 | U2 |
| 리컨사일러 테스트 | `.ci/test-claude-settings-reconcile.sh`, `.ci/test-omp-settings-reconcile.sh`, `.ci/test-codex-settings-reconcile.sh` | U1, U3 |
| 가드 실패 분기 | 선언 값을 뒤집거나 잘못된 타입으로 바꿔 렌더하면 해당 테스트가 경로 이름을 대며 실패한다 | U3 |
| 범위 확인 | `git diff --check`, `git status`, 변경 범위 제한 diff | 전체 |
| CI | 푸시 후 `render-dotfiles.yml`과 `ci.yml`을 terminal success까지 감시 | 전체 |

---

## Definition of Done

- R1부터 R20까지 모두 참이다.
- U1부터 U4까지 모든 테스트 시나리오가 통과한다.
- `git diff`가 `.chezmoidata/agents.yaml`, `.chezmoitemplates/agents-instructions.tmpl`, `.ci/test-agent-instructions.sh`, `.ci/test-claude-settings-reconcile.sh`, `.ci/test-omp-settings-reconcile.sh`, `.ci/test-codex-settings-reconcile.sh`, `AGENTS.md`, 그리고 이 계획 파일 외의 파일을 보여주지 않는다.
- 어떤 변경도 기존 메모리 파일이나 디렉터리를 지우지 않는다.
- 시도했다가 버린 코드나 임시 픽스처가 diff에 남아 있지 않다.
- `render-dotfiles.yml`과 `ci.yml`이 terminal success에 도달한다.

---

## Sources / Research

- GitHub issue [hyperlapse122/dotfiles#474](https://github.com/hyperlapse122/dotfiles/issues/474) — 문제 서술, 제안, 터치포인트, 수용 기준.
- `.chezmoidata/agents.yaml` — `agents.claude.settings` / `agents.omp.settings` / `agents.codex.settings` 선언 블록과 그 소유권 주석; `cleanupPeriodDays`와 `env.DISABLE_AUTOUPDATER`의 리프 주석 패턴; `agents.agy.settings: {}`.
- `.chezmoitemplates/claude-settings-validate.tmpl`, `omp-settings-validate.tmpl`, `codex-settings-validate.tmpl` — 경로 문법, 리프 전용 규칙, 다른 writer 네임스페이스 거부 목록, security allowlist. 새 경로 일곱 개가 모두 통과함을 확인.
- `.chezmoiscripts/70-agents/run_after_config-claude-settings.sh.tmpl` — 선언을 base64 JSON으로 싣고 리프 단위로 assert하는 구조, blocked path가 자기 자신만 억제한다는 규칙.
- `.ci/test-claude-settings-reconcile.sh` — `numeric_leaf_offenders` / `assert_numeric_leaves`와 손으로 만든 실패 픽스처 3종, `cleanup_period_offender`의 선언 직접 지목, `assert_declared_present`가 잘못된 타입을 보지 못하는 이유.
- `.ci/test-omp-settings-reconcile.sh` — 렌더 표면 needle 루프, `notify_offenders`, `$calls` / `$state` 픽스처 구조.
- `.ci/test-codex-settings-reconcile.sh` — 기존 리프 확인 구조.
- `.ci/test-agent-instructions.sh` — 네 하니스 × 두 OS 렌더 비교, harness isolation needle 행, 공유 본문 `NEEDLES` 목록, whole-file 픽스처 목록.
- Claude Code 2.1.268 바이너리의 설정 스키마 — `autoMemoryEnabled: z.boolean().optional()` ("Enable auto-memory for this project. When false, Claude will not read from or write to the auto-memory directory."), `autoDreamEnabled: z.boolean().optional()` ("Enable background memory consolidation (auto-dream)."), `autoMemoryDirectory` (기본 `~/.claude/projects/<sanitized-cwd>/memory/`). auto-memory 게이트 함수의 평가 순서: `CLAUDE_CODE_DISABLE_AUTO_MEMORY`가 참이면 끄고, 명시적 거짓이면 **켜고**, 그 뒤에야 설정 리프를 읽으며, 미선언이면 기본 켜짐. org memory는 `CLAUDE_CODE_DISABLE_ORG_MEMORY` / `allow_memory_sync` 엔타이틀먼트 / `tengu_haze_glass` 게이트로 별도 관리되며 설정 리프가 없다.
- 이 호스트의 `~/.claude/projects/*/memory/` — auto-memory가 실제로 동작 중임을 보여주는 이미 만들어진 디렉터리들.
- omp v18.1.17 바이너리의 도구 게이트 — `manage_skill`은 `settings.get("autolearn.enabled")`만 보고 `memory.backend`를 보지 않으며, `learn`은 거기에 더해 백엔드가 `hindsight`/`mnemopi`/`local`일 것을 요구한다. KTD8의 근거.
- omp v18.1.17 번들 설정 스키마와 이 호스트의 `omp config list --json` — `memory.backend` (enum `["off","local","hindsight","mnemopi","sharpshooter"]`, 기본 `off`), `memories.enabled` (boolean, 기본 `false`, UI 없음), `autolearn.enabled` / `autolearn.autoContinue` (boolean, 기본 `false`), 그리고 `memory.backend`가 고른 백엔드 아래에서만 의미가 있는 `mnemopi.*` / `sharpshooter.*` / `hindsight.*` / `providers.memoryModel`. 네 키 모두 기본값 상태에서도 평평한 점 표기 키로 보고됨.
- Codex rust-v0.154.0 — `codex features list`가 `memories`를 stage `stable`, 현재 상태 `false`로 보고. `-c features.memories=true|false`로 상태가 실제로 뒤집힘을 확인. `-c features.bogus_nonexistent=true`가 오류 없이 통과하므로 알 수 없는 feature 키는 조용히 무시됨. live `~/.codex/config.toml`에 `[features]` 테이블 없음. `~/.codex/memories_1.sqlite`가 이미 존재(`codex doctor`). `MemoriesToml` 구조체는 `disable_on_external_context`, `generate_memories`, `use_memories`, `dedicated_tools`, `max_raw_memories_for_consolidation`, `max_unused_days`, `max_rollout_age_days`, `max_rollouts_per_startup`, `min_rollout_idle_hours`, `extract_model`, `consolidation_model`을 담지만, 파이프라인 자체의 게이트는 feature 플래그다.
- Antigravity 1.2.0 바이너리 — 메모리 off 스위치는 `codeium_common_pb.UserSettings.disable_auto_generate_memories` (proto 필드 39)와 `cortex_pb.MemoryToolConfig.force_disable` / `.disable_auto_generate_memories`. 로컬 `~/.gemini/config/config.json`은 `exa.config_pb.UserConfig`로 매핑되고 그 `user_settings` 필드는 `jetbox_state_pb.UserSettings` — 그 메시지의 필드를 전수 확인한 결과 메모리 관련 필드가 없다. `CASCADE_ENABLE_AUTOMATED_MEMORIES`는 서버가 내려주는 실험 설정, `JB_DISABLE_AUTOGEN_MEMORY`는 JetBrains 플러그인 이벤트 이름이며 둘 다 로컬 선언 표면이 아니다.
- `AGENTS.md` — 검증 절차, Claude/Codex 설정 assertion 문단, omp 모델 배치 문단, 지시 타깃 문단, load-bearing 리프를 이름으로 열거하는 관행.
- `docs/plans/2026-09-09-1951-chore-omp-desktop-notifications-off-plan.md` — 같은 모양의 선행 작업(선언 + 리프 주석 + 타입 가드 + `AGENTS.md` 한 문장)의 구조와 "declaring is what pins" 논거.
- `docs/plans/2026-09-09-1718-chore-claude-transcript-retention-off-plan.md` — `agents.claude.settings`에 값 하나를 더하고 타입 가드를 붙인 선행 작업.
