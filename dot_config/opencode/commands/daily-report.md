---
name: daily-report
description: Analyze today's git commits and produce a concise daily work log in Korean aimed at a non-developer audience. Use on requests like "daily report", "daily log", "what did I do today", "work log", "일일 업무 보고", "일일 업무 로그".
---

# Daily Log Generator

Analyze today's git commit history and produce a concise daily work log **in Korean** that a non-developer can read.

## Workflow

1. Pull today's commits using the date range only (no author filter).
   - **Linux**

     ```bash
     git log --since="$(date +%Y-%m-%d) 00:00:00" --until="$(date -d '+1 day' +%Y-%m-%d) 00:00:00" --oneline --no-merges
     ```

   - **macOS / BSD**

     ```bash
     git log --since="$(date +%Y-%m-%d) 00:00:00" --until="$(date -v+1d +%Y-%m-%d) 00:00:00" --oneline --no-merges
     ```

   - **Windows PowerShell**

     ```powershell
     $start = (Get-Date).Date.ToString('yyyy-MM-dd HH:mm:ss')
     $end = (Get-Date).Date.AddDays(1).ToString('yyyy-MM-dd HH:mm:ss')
     git log --since="$start" --until="$end" --oneline --no-merges
     ```

2. Analyze the commit messages and group them from a **business perspective**:
   - Translate technical jargon into Korean a non-developer can understand
   - Drop trivial entries (lint fixes, typos, chore, docs, etc.)
   - Bundle related commits under a single higher-level item

3. Wrap the **entire final report in a single fenced ```plaintext code block** so the user can copy it to another device in one shot. No prose, headings, or commentary outside the fence. The leading two spaces inside the block are mandatory:
   ````plaintext
   ```plaintext
     - 상위 업무 항목
       - 세부 내용 1
       - 세부 내용 2
   ```
   ````

## Rules

- **Output container**: The final report MUST be a single fenced ```plaintext code block and nothing else. No surrounding prose, no "Here is..." preamble, no closing notes. The block is the entire response.
- **Language**: Korean only. All output must be written in Korean. Do not include English summaries, headings, or parenthetical translations.
- **Tone**: 간결하고 사실 중심. 기술 용어 최소화. 장황한 서술형 문장 지양.
- **Drop**: 자동 lint/format 수정, 문서 업데이트, VS Code 설정, yarn.lock 변경, 테스트 전용 커밋.
- **Include**: 신규 기능, 화면/UI 작업, 아키텍처 변경, 시스템 교체, 중요한 버그 수정만.
- **Depth**: 최대 2단계 (상위 항목 → 세부 내용).
- **Volume**: 총 5~10줄.
- **Sentence style**: 명사형 또는 짧은 동사구. 보고서가 아닌 메모 스타일.
- **Good example**:
  ```plaintext
    - 레거시 시스템 연동
      - 기존 .NET 기반 라이선스 모듈을 현재 프로젝트 구조에 통합
    - 레거시 호환 및 신규 인증이 적용된 라이선스 서비스 구축 (진행 중)
    - 빌드 시스템 표준화
      - Docker 이미지 생성 시 산출물 저장 위치 통일로 유지보수성 개선
  ```
- **Bad example**:
  ```plaintext
    - 인증 흐름 정리
      - 로그인 후 외부 서비스 승인 절차를 매끄럽게 확장
  ```
