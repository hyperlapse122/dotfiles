# OpenCode Agent Instructions

## Shell Operations

- **Always use `pwsh` (PowerShell)** as the primary shell for all shell operations — command execution, scripting, examples, and automation.
- When writing shell commands in responses or tool calls, use PowerShell syntax (e.g., `Get-ChildItem` or POSIX-compatible aliases like `ls` that work in pwsh — but never cmd-style syntax like `dir /s`).
- For file path separators, prefer `/` (PowerShell accepts both `\` and `/`).

### Fallback Shells

Only use a fallback shell when `pwsh` is unavailable or the task explicitly requires it.

| Platform | Primary | Fallback          |
|----------|---------|-------------------|
| Windows  | `pwsh`  | `cmd.exe`         |
| Linux    | `pwsh`  | `bash`, then `sh` |
| macOS    | `pwsh`  | `bash`, then `sh` |
