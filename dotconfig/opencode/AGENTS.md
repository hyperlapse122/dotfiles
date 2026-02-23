# OpenCode Agent Instructions

## Pull Requests / Merge Requests

- When creating a pull request or merge request, **always set the assignee to the authenticated user**.
  - GitHub: `gh pr create --assignee @me`
  - GitLab: `glab mr create --assignee $(glab api user | jq -r '.username')`
