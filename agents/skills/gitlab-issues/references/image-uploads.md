# GitLab image uploads from the CLI — reference

**MUST** upload through `glab api`. It reuses the session stored by `glab auth login` and
injects credentials internally. The agent never sees, reads, parses, or passes a token.

> The credential-handling guardrail is in core `AGENTS.md`: **MUST NOT** read or pass a
> GitLab token to any non-glab tool by any means — not `curl`/`wget`/`httpie` with a
> `PRIVATE-TOKEN`/`Authorization` header, not by reading `glab auth status -t`,
> `~/.config/glab-cli/config.yml`, the Keychain, libsecret, env vars (`GITLAB_TOKEN`,
> `GITLAB_API_TOKEN`, `CI_JOB_TOKEN`), or any `.env`/`op://` reference. Never ask the user
> to paste a token; the token already lives in glab's session.

**Flag — `--form`, not `--field`**:

- `-F` / `--field` builds a JSON body. **Wrong for files.**
- `--form` builds `multipart/form-data` and supports `@<path>` for files. **Required for
  `/uploads`.** No short alias for `--form`; spell it out.

**Endpoint**: `POST /projects/:id/uploads`. Returns:

```json
{
  "id": 123,
  "alt": "screenshot",
  "url": "/uploads/abc123def456/screenshot.png",
  "full_path": "/-/project/42/uploads/abc123def456/screenshot.png",
  "markdown": "![screenshot](/uploads/abc123def456/screenshot.png)"
}
```

Use the returned `markdown` field verbatim. **MUST NOT** hand-build from `url` or
`full_path` — `full_path` is a numeric project-id internal route, not a stable
project-relative reference. Only the `markdown` field's `/uploads/<hash>/<name>` form
survives copy-paste across issues, comments, and MRs in the same project.

**Filenames with spaces or non-ASCII** work — pass unquoted inside the `--form` value
string (e.g. `--form "file=@/path/with spaces/판독문.png"`). GitLab rewrites spaces to
underscores in the returned `alt` and `markdown`. Don't pre-rename — the rewrite is
server-side and consistent.

**Worked example — create an issue with an inline screenshot**:

```bash
# 1. Upload. Prefer :fullpath when the current repo remote points at the target project.
UPLOAD_JSON=$(glab api --method POST projects/:fullpath/uploads --form "file=@./screenshot.png")
IMAGE_MD=$(echo "$UPLOAD_JSON" | jq -r '.markdown')

# 2. Build description in a file (shell quoting mangles nested fences).
cat > /tmp/issue-body.md <<EOF
## Summary
Login form returns 500 on stale session.

## Screenshot
$IMAGE_MD
EOF

# 3. Create.
glab issue create --title "fix(auth): login 500 on stale session" \
  --description "$(cat /tmp/issue-body.md)" \
  --label "bug,area::auth,priority::high"
```

**Attaching to an existing issue**:

```bash
# Edit description in place.
CURRENT=$(glab issue view <iid> -F json | jq -r '.description')
printf '%s\n\n%s\n' "$CURRENT" "$IMAGE_MD" > /tmp/issue-body.md
glab issue update <iid> --description "$(cat /tmp/issue-body.md)"

# Or attach via a comment (preferred for evidence in an in-flight discussion).
glab issue note <iid> -m "Reproduction screenshot:

$IMAGE_MD"
```

**Self-managed hosts**: same host resolution as reading. From an unrelated cwd, pin the host
and keep the project path slash-separated:
`GITLAB_HOST=git.jpi.app glab api --method POST projects/products/examvue-duo/examvue-apps/uploads --form "file=@./screenshot.png"`.

**Verification**: if `glab api user` returns `401`, the glab session is missing or expired.
**STOP** and ask the user to run `glab auth login --hostname <host>`. **MUST NOT** work
around it with a raw token.
