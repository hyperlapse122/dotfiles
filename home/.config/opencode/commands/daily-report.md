---
name: daily-report
description: Analyze today's git commits and produce a concise daily work log aimed at a non-developer audience. Use on requests like "daily report", "daily log", "what did I do today", "work log".
---

# Daily Log Generator

Analyze today's git commit history and produce a concise daily work log that a non-developer can read.

## Workflow

1. Pull only **the user's own commits** for today (filter by `git config user.email`):
   - **macOS / Git Bash**
     ```bash
     git log --author="$(git config user.email)" --since="$(date +%Y-%m-%d) 00:00:00" --until="$(date -v+1d +%Y-%m-%d) 00:00:00" --oneline --no-merges
     ```
   - **Linux**
     ```bash
     git log --author="$(git config user.email)" --since="$(date +%Y-%m-%d) 00:00:00" --until="$(date -d "+1 day" +%Y-%m-%d) 00:00:00" --oneline --no-merges
     ```
   - **Windows PowerShell**
     ```powershell
     $start = (Get-Date).Date.ToString('yyyy-MM-dd HH:mm:ss')
     $end = (Get-Date).Date.AddDays(1).ToString('yyyy-MM-dd HH:mm:ss')
     $author = git config user.email
     git log --author="$author" --since="$start" --until="$end" --oneline --no-merges
     ```
   - If the result is empty, retry once using `git config user.name` (covers repos where email is unset).

2. Analyze the commit messages and group them from a **business perspective**:
   - Translate technical jargon into language a non-developer can understand
   - Drop trivial entries (lint fixes, typos, chore, docs, etc.)
   - Bundle related commits under a single higher-level item

3. Output in the following format (the leading two spaces are mandatory):
   ```plaintext
     - High-level work item
       - Detail 1
       - Detail 2
   ```

## Rules

- **Tone**: Concise and factual. Minimize technical jargon. Avoid verbose narrative sentences.
- **Drop**: automatic lint/format fixes, doc updates, VS Code settings, yarn.lock changes, test-only commits.
- **Include**: new features, screen/UI work, architecture changes, system swaps, important bug fixes only.
- **Depth**: at most 2 levels (high-level → detail).
- **Volume**: 5 to 10 lines total.
- **Sentence style**: nouns or short verb phrases. Memo style over report style.
- **Good example**:
  ```plaintext
    - Legacy system integration
      - Integrated the existing .NET-based license module into the current project structure
    - Built a license service with legacy compatibility and the new auth applied (in progress)
    - Build system standardization
      - Unified output storage location during Docker image creation to improve maintainability
  ```
- **Bad example**:
  ```plaintext
    - Tidied up the authentication flow
      - Smoothly extended the post-login external-service approval procedure
  ```
