---
name: daily-report
description: >
  Daily work-log generator — sweep EVERY repository under `~/src` (all hosts,
  all groups), collect today's commits authored by the user, and produce one
  concise daily work log in Korean, grouped by group → repository, aimed at a
  non-developer audience. Load this BEFORE writing any daily/work log or status
  summary from git history. Triggers: "daily report", "daily log", "what did I
  do today", "work log", "일일 업무 보고", "일일 업무 로그". It covers the
  `~/src` bare-repo enumeration and the per-OS date-range `git log` commands
  (Linux / macOS-BSD / Windows PowerShell), the mandatory author filter, the
  business-perspective grouping rules (what to drop, what to include), the
  group → repository → detail output shape inside a single ```plaintext fence,
  and the Korean tone/depth/volume rules with good and bad examples. Do NOT
  load it for commit-message writing or branch hygiene (use `git-workflow`), or
  for PR/MR summaries (use `pr-mr`).
---

# Daily Log Generator

Sweep **every repository under `~/src`**, collect today's commits **authored by the user**, and produce one concise daily work log **in Korean** that a non-developer can read, organized **by group and repository**.

Scope is the whole `~/src` tree — never a single repo, and never "the repo I happen to be `cd`'d into". Repos outside `~/src` (e.g. the chezmoi source dir at `~/.local/share/chezmoi`) are OUT of scope unless the user explicitly asks for them.

## Layout assumptions

`~/src` follows `~/src/<host>/[<group>/]<project>/<worktree>`, and a project directory is **not** a working tree — it is a bare repo (`.bare/`) plus its worktrees. So:

- Enumerate **`.bare` directories**, not worktrees. One `.bare` = one repository.
- Query each with `git --git-dir=<project>/.bare log`. All worktree branches share that object store, so nothing is missed.
- `<group>` is the second-to-last path segment (`examvue-365-flow`, `examvue-duo`); a group-less project has none.

## Workflow

1. **Collect** today's commits across every repo. The author filter is **mandatory**: `--all` walks fetched remote branches too, so without it a teammate's commits land in your log.

   - **Linux**

     ```bash
     since="$(date +%Y-%m-%d) 00:00:00"
     until="$(date -d '+1 day' +%Y-%m-%d) 00:00:00"
     me="$(git config --get user.email)"

     find ~/src -mindepth 3 -maxdepth 4 -type d -name .bare -prune | sort | while read -r bare; do
       rel="${bare%/.bare}"; rel="${rel#"$HOME"/src/}"
       log=$(git --git-dir="$bare" log --all --no-merges --author="$me" \
         --since="$since" --until="$until" --date=format:'%H:%M' --pretty='  %ad %s')
       [ -n "$log" ] && printf '\n=== %s\n%s\n' "$rel" "$log"
     done
     ```

   - **macOS / BSD** — same loop, only the `until` line changes:

     ```bash
     until="$(date -v+1d +%Y-%m-%d) 00:00:00"
     ```

   - **Windows PowerShell**

     ```powershell
     $since = (Get-Date).Date.ToString('yyyy-MM-dd HH:mm:ss')
     $until = (Get-Date).Date.AddDays(1).ToString('yyyy-MM-dd HH:mm:ss')
     $me = git config --get user.email

     Get-ChildItem -Path ~/src -Directory -Filter .bare -Depth 3 | Sort-Object FullName | ForEach-Object {
       $rel = (Split-Path $_.FullName -Parent).Replace("$HOME/src/", '')
       $log = git --git-dir=$_.FullName log --all --no-merges --author=$me `
         --since=$since --until=$until --date=format:'%H:%M' --pretty='  %ad %s'
       if ($log) { "`n=== $rel"; $log }
     }
     ```

   A different day: shift the two date expressions (e.g. `date -d 'yesterday'` / `date -d '-1 day'` for the `until`). Never change the author filter.

2. **Read the diff when the subject is not enough.** A commit subject is a technical shorthand; the log is for a non-developer. When a repo's subjects don't say *what changed for the business*, inspect that repo's commits — `git --git-dir=<bare> show --stat <sha>` — before writing its line. Don't guess, and don't just transliterate the subject.

3. **Group from a business perspective**, per repository:
   - Translate technical jargon into Korean a non-developer can understand
   - Drop trivial entries (lint/format fixes, typos, chore, docs, lockfile bumps, etc.)
   - Bundle related commits under a single higher-level item — a 20-commit refactor is one line, not twenty
   - A repo whose commits are ALL trivial is dropped entirely, along with a group left empty by that

4. **Emit** the report as a **single fenced ```plaintext code block**, nested 그룹 → 레포지토리 → 세부 내용, so the user can copy it to another device in one shot. No prose, headings, or commentary outside the fence. The leading two spaces inside the block are mandatory:

   ````plaintext
   ```plaintext
     - 그룹명
       - 레포지토리명
         - 세부 내용 1
         - 세부 내용 2
   ```
   ````

## Rules

- **Output container**: The final report MUST be a single fenced ```plaintext code block and nothing else. No surrounding prose, no "Here is..." preamble, no closing notes. The block is the entire response.
- **Language**: Korean only. All output must be written in Korean. Do not include English summaries, headings, or parenthetical translations.
- **Identifiers stay verbatim**: 그룹명과 레포지토리명은 디렉터리 이름 그대로 (`examvue-365-flow`, `telerad-frontend`) — 번역·의역·한글 표기 금지. 한국어로 쓰는 것은 세부 내용뿐.
- **Depth**: 정확히 3단계 (그룹 → 레포지토리 → 세부 내용). 그룹이 없는 프로젝트는 레포지토리를 최상위에 둔다.
- **Host segment**: 출력에서 `<host>`는 생략한다. 단, 서로 다른 host에 같은 이름의 그룹이 있어 모호할 때만 `git.jpi.app / examvue-duo`처럼 앞에 붙인다.
- **Omission**: 오늘 커밋이 없는 레포지토리·그룹은 아예 출력하지 않는다 (빈 항목이나 "변경 없음" 줄을 만들지 말 것). 전체 트리에 커밋이 하나도 없으면 블록 안에 `  - 금일 커밋 이력 없음` 한 줄만 출력한다.
- **Ordering**: 작업량이 많은 그룹·레포지토리부터. 동률이면 이름순.
- **Tone**: 간결하고 사실 중심. 기술 용어 최소화. 장황한 서술형 문장 지양.
- **Drop**: 자동 lint/format 수정, 문서 업데이트, VS Code 설정, 락파일(bun.lock 등) 변경, 테스트 전용 커밋.
- **Include**: 신규 기능, 화면/UI 작업, 아키텍처 변경, 시스템 교체, 중요한 버그 수정만.
- **Volume**: 레포지토리당 세부 내용 1~4줄, 전체 30줄 이내. 한 레포에 커밋이 아무리 많아도 세부 내용을 나열하지 말고 묶을 것.
- **Sentence style**: 명사형 또는 짧은 동사구. 보고서가 아닌 메모 스타일.
- **Good example**:
  ```plaintext
    - examvue-365-flow
      - telerad-frontend
        - 판독 워크리스트 화면 신규 구축
        - 공용 디자인 시스템 기반으로 로그인/결제 화면 재작업
      - shadcn-registry
        - 사내 공용 UI 컴포넌트 레지스트리 초기 배포
    - examvue-duo
      - examvue-apps
        - 레거시 .NET 라이선스 모듈을 현재 구조에 통합
        - 빌드 산출물 저장 위치 통일로 유지보수성 개선
  ```
- **Bad example** (그룹·레포 누락, 커밋 나열, 의미 없는 의역):
  ```plaintext
    - 인증 흐름 정리
      - 로그인 후 외부 서비스 승인 절차를 매끄럽게 확장
    - telerad-frontend
      - refactor(ui): re-skin landing page 커밋 반영
      - refactor(ui): re-skin about page 커밋 반영
  ```
