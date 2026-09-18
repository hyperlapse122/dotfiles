# GitLab issues source
Fetch GitLab issues with `glab` and return them in the shared item schema.
Item ids use the form `group/project#<iid>`.
## Availability
GitLab tools unavailable — source skipped this run.
GitLab write capability unavailable — source degrades to read-only ingest; items will be marked ack_deferred.
## Fetch
During fetch, use only `glab` read commands.
List issues with `--order updated_at --sort desc --output json --page <n> --per-page 100`.
Keep the issues where `updated_at >= cursor`.
Resolve each author with `members/all/<author-id>`.
Fetch is all-or-nothing.
Empty list when none or when the issue is confidential.
## Confidential issues
Confidential GitLab issue group/project#<iid> is returned with `sensitive: true`.
## Acknowledgement
Label an item with `glab issue update <iid> --repo <group/project> --label <configured-label>`.
