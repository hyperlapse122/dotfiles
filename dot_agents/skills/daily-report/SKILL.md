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
  landed-vs-unmerged split that marks work not yet on the default branch as
  `(진행 중)`, the business-perspective grouping rules (what to drop, what to
  include), the group → repository → detail output shape inside a single
  ```plaintext fence, and the Korean tone/depth/volume rules with good and bad
  examples.
---

# Daily Log Generator

Sweep **every repository under `~/src`**, collect today's commits **authored by the user**, and produce one concise daily work log **in Korean** that a non-developer can read, organized **by group and repository**.

Scope is the whole `~/src` tree — never a single repo, and never "the repo I happen to be `cd`'d into". Repos outside `~/src` (e.g. the chezmoi source dir at `~/.local/share/chezmoi`) are OUT of scope unless the user explicitly asks for them.

## Layout assumptions

`~/src` follows `~/src/<host>/[<group>/]<project>/<worktree>`, and a project directory is **not** a working tree — it is a bare repo (`.bare/`) plus its worktrees. So:

- Enumerate **`.bare` directories**, not worktrees. One `.bare` = one repository.
- Query each with `git --git-dir=<project>/.bare log`. All worktree branches share that object store, so nothing is missed.
- `<group>` is the second-to-last path segment (`examvue-365-flow`, `examvue-duo`); a group-less project has none.
- The **default branch differs per repo** (`main`, `develop`, `dev`, …) — read it from the bare HEAD (`git --git-dir=<bare> symbolic-ref --short HEAD`), never assume `main`.

## Workflow

1. **Collect** today's commits across every repo, split into **landed** and **not yet merged into the default branch**. Two facts make this work:

   - The author filter is **mandatory**: `--all` walks fetched remote branches too, so without it a teammate's commits land in your log.
   - "Merged" = reachable from the default branch — its **local** ref and its `origin/` counterpart both count, so a commit you made on `develop` but haven't pushed still reads as landed. Everything else (`--all --not <those refs>`) is 진행 중.

   The refs go into the **positional parameters**, not a plain string: zsh does not word-split an unquoted variable, so `git log $refs` would pass `" develop origin/develop"` as ONE bad revision. This form is correct under both bash and zsh.

   - **Linux**

     ```bash
     since="$(date +%Y-%m-%d) 00:00:00"
     until="$(date -d '+1 day' +%Y-%m-%d) 00:00:00"
     me="$(git config --get user.email)"

     find ~/src -mindepth 3 -maxdepth 4 -type d -name .bare -prune | sort | while read -r bare; do
       rel="${bare%/.bare}"; rel="${rel#"$HOME"/src/}"
       def="$(git --git-dir="$bare" symbolic-ref --short HEAD 2>/dev/null)"

       set --   # collect the default-branch refs that actually exist
       for r in "$def" "origin/$def"; do
         git --git-dir="$bare" rev-parse --verify -q "$r" >/dev/null 2>&1 && set -- "$@" "$r"
       done
       [ $# -eq 0 ] && continue   # default branch unresolvable — see the rules

       landed=$(git --git-dir="$bare" log "$@" --no-merges --author="$me" \
         --since="$since" --until="$until" --date=format:'%H:%M' --pretty='  %ad %s')
       wip=$(git --git-dir="$bare" log --all --not "$@" --no-merges --author="$me" \
         --since="$since" --until="$until" --date=format:'%H:%M' --pretty='  %ad %s  [진행 중]')

       [ -n "$landed$wip" ] && printf '\n=== %s (기본 브랜치: %s)\n%s\n%s\n' "$rel" "$def" "$landed" "$wip"
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
       $bare = $_.FullName
       $rel = (Split-Path $bare -Parent).Replace("$HOME/src/", '')
       $def = git --git-dir=$bare symbolic-ref --short HEAD
       $refs = @($def, "origin/$def") | Where-Object {
         git --git-dir=$bare rev-parse --verify -q $_ 2>$null; $LASTEXITCODE -eq 0
       }
       if (-not $refs) { return }

       $landed = git --git-dir=$bare log @refs --no-merges --author=$me `
         --since=$since --until=$until --date=format:'%H:%M' --pretty='  %ad %s'
       $wip = git --git-dir=$bare log --all --not @refs --no-merges --author=$me `
         --since=$since --until=$until --date=format:'%H:%M' --pretty='  %ad %s  [진행 중]'
       if ($landed -or $wip) { "`n=== $rel (기본 브랜치: $def)"; $landed; $wip }
     }
     ```

   A different day: shift the two date expressions (e.g. `date -d 'yesterday'` / `date -d '-1 day'` for the `until`). Never change the author filter.

2. **Read the diff when the subject is not enough.** A commit subject is a technical shorthand; the log is for a non-developer. When a repo's subjects don't say _what changed for the business_, inspect that repo's commits — `git --git-dir=<bare> show --stat <sha>` — before writing its line. Don't guess, and don't just transliterate the subject.

3. **Group from a business perspective**, per repository:
   - Translate technical jargon into Korean a non-developer can understand
   - Drop trivial entries (lint/format fixes, typos, chore, docs, lockfile bumps, etc.)
   - Bundle related commits under a single higher-level item — a 20-commit refactor is one line, not twenty
   - A repo whose commits are ALL trivial is dropped entirely, along with a group left empty by that
   - Suffix a detail line with **` (진행 중)`** when any commit behind it carries the `[진행 중]` marker — see the rules

4. **Emit** the report as a **single fenced ```plaintext code block**, nested 그룹 → 레포지토리 → 세부 내용, so the user can copy it to another device in one shot. No prose, headings, or commentary outside the fence. Start the top-level group (or a group-less repository) at column 1 with no leading spaces; indentation comes only from the group → repository → detail hierarchy:

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
- **Depth**: 정확히 3단계 (그룹 → 레포지토리 → 세부 내용). 최상위 그룹은 앞 공백 없이 시작하고, 그룹이 없는 프로젝트는 레포지토리를 앞 공백 없이 최상위에 둔다.
- **Host segment**: 출력에서 `<host>`는 생략한다. 단, 서로 다른 host에 같은 이름의 그룹이 있어 모호할 때만 `git.jpi.app / examvue-duo`처럼 앞에 붙인다.
- **Omission**: 오늘 커밋이 없는 레포지토리·그룹은 아예 출력하지 않는다 (빈 항목이나 "변경 없음" 줄을 만들지 말 것). 전체 트리에 커밋이 하나도 없으면 블록 안에 `- 금일 커밋 이력 없음` 한 줄만 출력한다.
- **`(진행 중)` 표기**: 기본 브랜치에 아직 머지되지 않은 커밋(`[진행 중]` 마커가 붙어 나온 것)에서 비롯된 세부 내용은 줄 끝에 ` (진행 중)`를 붙인다.
  - 한 항목이 머지된 커밋과 미머지 커밋을 함께 묶었다면 **미머지가 하나라도 섞인 순간 `(진행 중)`** — 아직 다 실리지 않은 작업이므로 완료로 보고하지 않는다.
  - 전부 머지된 항목에는 절대 붙이지 않는다. 표기는 **세부 내용 줄에만** 붙이고 그룹·레포지토리 줄에는 붙이지 않는다.
  - 기본 브랜치를 못 찾은 레포(bare HEAD도 `origin/<def>`도 없음)는 머지 여부를 판단할 수 없으므로 표기를 생략하고, 그 사실을 추측으로 메우지 않는다.
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
    - 공용 디자인 시스템 기반으로 로그인/결제 화면 재작업 (진행 중)
  - shadcn-registry
    - 사내 공용 UI 컴포넌트 레지스트리 초기 배포
- examvue-duo
  - examvue-apps
    - 레거시 .NET 라이선스 모듈을 현재 구조에 통합
    - 빌드 산출물 저장 위치 통일로 유지보수성 개선 (진행 중)
```
- **Bad example** (그룹·레포 누락, 커밋 나열, 의미 없는 의역, 레포 줄에 붙인 `(진행 중)`):
```plaintext
- 인증 흐름 정리
  - 로그인 후 외부 서비스 승인 절차를 매끄럽게 확장
- telerad-frontend (진행 중)
  - refactor(ui): re-skin landing page 커밋 반영
  - refactor(ui): re-skin about page 커밋 반영
```
