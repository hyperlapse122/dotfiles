# Sweep interview
The interview collects the settings a sweep run needs before it fetches
anything. Ask one question at a time and record each answer.
## Sources
Ask which sources the sweep reads:
- `github-issues`: repository issues by label
- `slack`: channel threads
- `email`: labelled messages
## Targets
Ask where each source points:
- `github-issues` takes an `owner/repo` target.
- `slack` takes a channel name.
- `email` takes a label name.
## Labels
Ask which labels mark acknowledged and resolved items. Defaults:
- acknowledged: `ack`
- resolved: `resolved`
## Cursor
Ask for the earliest update time to read. Default: seven days ago.
## Confirmation
Read the answers back and ask for confirmation before writing the config.
The interview ends when the user confirms.
