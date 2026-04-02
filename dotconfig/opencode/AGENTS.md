# OpenCode Agent Instructions

## Pull Requests / Merge Requests

- When creating a pull request or merge request, **always set the assignee to the authenticated user**.
  - GitHub: `gh pr create --assignee @me`
  - GitLab: `glab mr create --assignee $(glab api user | jq -r '.username')`
- GitLab MRs should **always include `--remove-source-branch`** to clean up after merge.
- When the MR originates from a GitLab issue, use `--related-issue <issue-number>` to link them.

### GitLab MR Example

```bash
glab mr create \
  --assignee "$(glab api user | jq -r '.username')" \
  --remove-source-branch \
  --related-issue 42 \
  --title "Fix login redirect loop" \
  --description "Resolves #42"
```

## Figma

- When given a Figma link, **always use the `figma` MCP** to retrieve design information. Never access Figma URLs directly (e.g., via web fetch or browser automation).
- If the `figma` MCP is unavailable or returns an error, **ask the user to fix the MCP configuration** instead of attempting alternative access methods.

## Interactive / Long-Running Processes

- When launching interactive or long-running processes (e.g., dev servers, watch modes, TUI apps), **always use the `tmux` tool** (`mcp_interactive_bash`) instead of regular shell execution.
- This prevents blocking the agent session and allows the process to run in the background while continuing other work.

## Scripting Runtime

- **Never use Python** for scripting, tooling, or any code generation tasks.
- Use **Node.js**, **Deno**, or **Bun** instead.
- When a task requires a script (e.g., data transformation, automation, CLI tools), default to TypeScript/JavaScript running on one of the above runtimes.
