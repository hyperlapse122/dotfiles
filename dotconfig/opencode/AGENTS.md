# OpenCode Agent Instructions

## Pull Requests / Merge Requests

- When creating a pull request or merge request, **always set the assignee to the authenticated user**.
  - GitHub: `gh pr create --assignee @me`
  - GitLab: `glab mr create --assignee $(glab api user | jq -r '.username')`

## Figma

- When given a Figma link, **always use the `figma` MCP** to retrieve design information. Never access Figma URLs directly (e.g., via web fetch or browser automation).
- If the `figma` MCP is unavailable or returns an error, **ask the user to fix the MCP configuration** instead of attempting alternative access methods.
