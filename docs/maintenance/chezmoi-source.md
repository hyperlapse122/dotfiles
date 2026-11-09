# Chezmoi Source Maintenance

This guide explains the architecture of the chezmoi source directory (`home/`), script lifecycles, naming and ordering rules, dependency tracking signatures, modify-template conventions, and the onboarding procedure for AI harnesses.

## Source Directory Layout

The repository uses `.chezmoiroot` at the project root to map chezmoi's source state to the `./home` directory:

```
dotfiles/
├── .chezmoiroot            # Points to "home"
├── .chezmoi-bootstrap.toml # Hook-free configuration for worktree preparation
├── README.md               # Quick start and repository overview
├── docs/                   # Documentation tree
└── home/                   # Authoritative chezmoi source
    ├── .chezmoiignore      # Ignored files (README.md, .secrets, OS-specific files)
    ├── .chezmoi.toml.tmpl  # Chezmoi persistent configuration template
    ├── .chezmoidata/       # Structured YAML and JSON data dictionaries
    ├── .chezmoiscripts/    # Ordered lifecycle scripts (pre-apply, post-apply)
    ├── .chezmoitemplates/  # Reusable template snippets and modify partials
    ├── .secrets/           # Encrypted GPG secret source
    └── dot_* / private_*   # Managed dotfiles applied to user home
```

### Data Files (`.chezmoidata/`)

Chezmoi automatically merges all files in `.chezmoidata/` into a single global data dictionary accessible in templates:
- `git.yaml`: Global Git author name and email.
- `gpg.yaml`: GPG encryption recipient key and OS-specific executable paths.
- `windows.yaml`: Windows host application WinGet package list.
- `personal-apps.json` / `personal-app-lock.json`: Personal CLI declarations and locked SHA-256 release pins.
- `fonts.json` / `font-lock.json`: Desktop font selections and generated release/archive-member SHA-256 pins, exposed as `fonts` and `fontLocks`.
- `harness-plugins.json` / `harness-plugin-lock.json`: AI harness plugin declarations and release pins.
- `harness-skills.json`: Shared user-scope skill pack declarations (`harnessSkills`), with the reviewed SKILL.md frontmatter keys and each skill's expected `allowed-tools` value. Their release pins live in `harness-plugin-lock.json` under `harnessSkillLocks`.

> **Note:** Filenames in `.chezmoidata/` do not create namespaces in chezmoi. Ensure top-level dictionary keys remain unique across files.

---

## External Asset Preparation

`home/.chezmoitemplates/external-assets/` declares immutable downloads and archive selections.
The `external-assets-manifest` and `external-asset-roots` templates render the isolated preparation source and its owned destinations.
The `run_before_05-external-assets.*` scripts run before native asset consumers during explicit application.

The native PowerShell or POSIX preparation script uses a separate, hook-free chezmoi invocation to download, verify, and extract changed assets under `~/.cache/dotfiles/external-assets`.
Fonts are selected together per archive; Codex binaries and package resources are selected together per package.
`harness-skills.toml.tmpl` declares one exact destination per shared skill in each [skill root](../guides/harness-plugins.md#skill-roots) whose harnesses are targeted on the current platform, and extracts only that skill's subtree into it.
Only the declared roots are copied to their existing home locations; exact cleanup is limited to owned resource directories.

Completed preparation is reused while the rendered declarations and cached file metadata match.
An unchanged run checks file metadata instead of reading full archives or payload contents.
Missing or changed installed files are restored from the prepared cache.
This can miss modifications that retain size and modification time.

Run `mise run assets:verify` to fully verify cached content and reconcile installed assets, or `mise run assets:refresh` to additionally force downloads.
Both tasks explicitly apply personal configuration from the current worktree.
An outer chezmoi `--refresh-externals` flag does not propagate to the isolated preparation command.

These script-managed assets are outside the ordinary `chezmoi managed`, `diff`, and `verify` inventory.
Use the explicit asset verification task for their integrity checks.
Worktree bootstrap skips scripts and therefore does not download, extract, or install these assets.

## Script Lifecycle and Ordering

Use managed files whenever possible. Use scripts only for system actions that cannot be expressed as declarative files (e.g. Updating registry values, configuring native credential helpers, or installing WinGet packages).

### Lifecycle Phases

Chezmoi executes scripts based on filename prefixes:
- **`run_before_`**: Runs before any managed files are applied. Use for preflight safety checks (e.g. Checking GPG home safety or virtualization availability).
- **`run_onchange_`**: Runs after managed files are written, only when the rendered content of the script changes. Use for change-driven actions (e.g. Reconciling plugin caches or running WinGet).
- **`run_once_`**: Runs only once per unique rendered content. Use sparingly.
- **`run_after_`**: Runs unconditionally on every apply after managed files are written. Use for state repairs that must run on every apply (e.g. Native keyring credential reconciliation).

### Ordering and Naming Conventions

Maintain strict ordering within phases using zero-padded two-digit numbers:

```
run_before_05-check-windows-prerequisites.ps1.tmpl
run_before_10-check-gpg-home.ps1.tmpl
run_onchange_after_10-personal-app-path.sh.tmpl
run_onchange_after_20-harness-plugins.sh.tmpl
run_after_25-windows-build-environment.ps1.tmpl
run_after_30-install-fonts.sh.tmpl
run_after_40-github-auth.py.tmpl
run_after_45-gitlab-auth.py.tmpl
```

Keep scripts idempotent and fail-safe: an error in any script must return a non-zero exit code to stop subsequent execution and preserve the environment.

The OS-conditional `run_after_30-install-fonts.*` hooks reconcile fonts on every explicit apply so missing files and Windows registrations can be repaired without changing the lock.
`home/.chezmoitemplates/external-assets/fonts.toml.tmpl` selects archive members; `font-index.tsv` supplies their member hashes to the native installers.
Native installation owns prefixed filenames and an installation manifest, never the entire user font directory.
See [User Fonts](../guides/fonts.md) for paths and recovery.

### Dependency Signatures

Chezmoi hashes the rendered script body to decide if a `run_onchange_` script has changed. If the script consumes data from `.chezmoidata` or templates from `.chezmoitemplates`, changes to those dependencies will not trigger execution unless their hashes appear in the script body.

Include dependency signatures as comments near the top of the script:

```gotemplate
# file gpg-agent-config sha256: {{ include ".chezmoitemplates/gpg-agent-config" | sha256sum }}
# data windows.apps sha256: {{ .windows.apps | toJson | sha256sum }}
```

Guidelines:
- Hash only the specific data fields consumed by the script (e.g. `.windows.apps`), not the entire global data dictionary.
- Serialize data structures with `toJson` before piping to `sha256sum` to ensure deterministic formatting.
- Do not hash mutable destination files or timestamps.

---

## Windows Script Execution

- **Extension:** Always use `.ps1.tmpl` for Windows scripts rather than `.cmd` wrappers or inline commands.
- **BOM Requirement:** Output a UTF-8 Byte Order Mark (BOM) using `{{ "\ufeff" -}}` inside Windows template conditions so Windows PowerShell 5.1 interprets non-ASCII characters correctly.
- **Profile Independence:** Scripts must execute with `-NoProfile` and avoid depending on user profiles or interactive input.
- **Interpreter Selection:** Chezmoi configuration templates point to the built-in system Windows PowerShell executable by absolute path, ensuring first-run execution succeeds before modern PowerShell 7 (`pwsh`) is installed.

---

## Modify Templates

Modify templates transform existing files on the host in-place rather than completely overwriting them.

### Conventions

- **Header Marker:** The first line must be `chezmoi:modify-template`.
- **Naming:** Modify templates do **not** use the `.tmpl` extension (e.g. `modify_private_settings.json`).
- **Permissions:** Use `private_` prefix to enforce `0600` permissions on POSIX hosts.
- **Preservation:** Modify scripts must parse existing configuration, update only repository-owned keys, and preserve unowned user settings and formatting where possible.
- **Failure:** If parsing fails or the existing file is malformed, the script must fail immediately rather than overwriting the file with a blank template.

---

## Tool Retirement

Retiring a tool makes it unmanaged. Remove its repository-owned installation declarations, tool-specific release and binary pins, configuration sources, instruction adapters, and tool-specific integration code. Later applies must leave its installed executable, settings, credentials, plugin state, and session data on disk without reinstalling or reconciling them. A fresh home must not acquire the retired tool or its configuration.

Removing source management and deleting destination state are separate operations. Do not add cleanup scripts, deletion manifests, or uninstall commands to implement retirement. Uninstalling a binary or deleting existing user configuration or data requires a separate explicit request. Check for surviving scripts, external-asset reconciliation, or directory ownership rules that could still restore or delete retired destinations; absence from `chezmoi managed` alone does not prove retirement.

An explicitly requested integration removal inside a still-managed configuration file is different. Update the file's existing `modify` transformation to remove the owned entry from the current destination and keep it absent on repeated applies. Merely removing the code that inserts the entry leaves existing homes unchanged. Preserve unrelated entries and settings, and retain the modify-template parsing and failure rules above.

Keep shared resources managed for remaining consumers. Retiring one harness must not remove the shared Compound Engineering release/commit pin, skills, instruction template, or assets that another harness still uses. Remove only tool-exclusive declarations and branches from those resources.

### Example: Retiring omp

For an `omp` retirement, remove its installation declarations and binary pin from the repository, along with its configuration sources, instruction adapter, and exclusive integration code. Leave the installed `omp` executable and `~/.omp` directory on existing PCs, including credentials, plugins, and sessions. Continue managing shared Compound Engineering resources for the other harnesses.

When that request explicitly includes removing the T3 Code provider entry, use the existing `home/private_dot_t3/private_userdata/modify_private_settings.json` adapter and its `t3-code-settings` partial to remove only the `omp` provider entry from the destination settings. The entry must stay absent after repeated applies while unrelated providers and user settings survive. This example defines the retirement requirements; it does not assert that `omp` has already been retired in this checkout.

### Verification in Disposable Homes

Run retirement checks against both an existing-home fixture and a separate fresh-home fixture. Bind chezmoi to the current worktree source, use a hook-free test configuration and isolated persistent state, and redirect home variables and every script's destination to the disposable home. Inspect the rendered scripts before executing them: `--destination` alone does not isolate native installers, credentials, application homes, or OS actions. Stub external installers and OS operations or use a disposable VM/container when they cannot be redirected safely. Do not run `mise run apply` against the real home for these checks.

1. **Existing home:** Seed representative pre-retirement state in the fixture: the executable, settings, dummy credentials, plugin state, and session data. Include the old integration entry in the still-managed configuration file, together with unrelated provider entries and user settings. Record file paths and content hashes before applying the retirement source.
2. Apply the current worktree source to the isolated fixture. Confirm all retired files and data survive byte-for-byte, the executable remains present, and no retired installer or reconciler runs. Confirm the explicitly removed integration entry is absent and unrelated settings retain their values.
3. Edit a retired settings file and remove a retired file inside the fixture. Reapply and confirm the edit survives and the missing file is not recreated. Confirm the integration entry stays absent on this repeated apply. Reinsert the old entry and apply again to prove the `modify` transformation removes existing entries rather than merely declining to add them. Check unrelated settings after each apply.
4. **Fresh home:** Start with an empty destination and separate test state, then apply the retirement source under the same isolation. Confirm the retired executable, configuration, instruction adapter, plugin state, and integration entry are never created, and no retired installation is attempted. Do not copy the existing-home fixture or reuse its chezmoi script execution state.
5. In both fixtures, verify remaining harnesses still receive their shared Compound Engineering pins, skills, instructions, and assets. Inspect both the native chezmoi inventory and script-managed asset destinations. Repeat the fresh-home apply to check idempotence.

For `omp`, these checks specifically cover preservation of the installed executable and `~/.omp` contents, no restoration of changed or missing retired files, and removal of its T3 Code provider entry on every apply. Fresh-home checks must show no `omp` executable, `~/.omp` configuration, or T3 Code `omp` provider entry.

Worktree bootstrap remains read-only with respect to personal settings: initialize with `mise install` and the repository's hook-free chezmoi configuration. Retirement verification is an explicit isolated test, never a new bootstrap step.

---

## Shared User-Scope Harness Onboarding

All AI harnesses managed by this repository must connect their user-scope instructions to a single shared template.

### 1. The Shared Instruction Template

`home/.chezmoitemplates/agent-instructions` contains:
- Common instructions shared across all AI agents.
- Conditional blocks for harness-specific logic:
  ```gotemplate
  {{ if eq .harness "example" }}
  # Harness-specific instructions
  {{ end }}
  ```

### 2. Adding a New Harness Adapter

To onboard a new harness (e.g. `example-harness`):
1. Identify the harness's documented user-scope instruction file (e.g. `~/.config/example/AGENTS.md`).
2. Add a thin template adapter in `home/` at the matching relative path (e.g. `home/private_dot_config/private_example/private_empty_AGENTS.md.tmpl`).
3. Pass the harness identifier and native `.chezmoi` object into the shared template; the baseline reads `.chezmoi.os` to select host-specific guidance:
   ```gotemplate
   {{- template "agent-instructions" (dict "harness" "example" "chezmoi" .chezmoi) -}}
   ```
4. Register, install, and enable the repository-pinned Compound Engineering plugin through the harness's native user-scope mechanism. Codex uses native `plugin marketplace add` and `plugin add`; Claude uses `plugin marketplace add`, `plugin install`, and `plugin enable` with `--scope user`. Antigravity uses its supported native plugin commands. Reuse the existing release/commit pin, preserve unrelated plugins and settings, and install only during explicit apply.
5. Make the harness discover each shared user-scope skill exactly once. In `home/.chezmoitemplates/external-assets/harness-skills.toml.tmpl`, add the harness's `personalApps` identifier to the reader list of the shared skill root it reads natively, so that root renders whenever the harness is targeted. If the harness also reads another managed root, its native listing must still show each skill once. Grok, for example, has Claude skill compatibility turned off. See [Exactly-Once Discovery](../guides/harness-plugins.md#exactly-once-discovery).
6. For T3 integration, select `context = t3` from the same shared template with the explicit native `harness` identifier. The resulting private addition file must omit the common baseline. Pass it through the supported native launch option or SDK equivalent while retaining native user/repository discovery and the normal account home. `scripts/t3-instructions.py` reconciles the current Codex, Claude, and pi launch options during explicit application; its private state preserves original options for reapplication and removal. Document unsupported adapters instead of creating a shadow profile or substituting untrusted application context.

Claude's adapter is `home/private_dot_claude/private_empty_CLAUDE.md.tmpl`, targeting `~/.claude/CLAUDE.md` with `harness = claude`. Its private settings merge and after hooks preserve unrelated state. The POSIX hook parses native JSON through the invoking chezmoi executable with a hook-free config; it does not assume Python or jq can be resolved outside the worktree.

### 3. Verification

Verify in a disposable sandbox:
- The common instructions are included.
- Foreign harness conditional blocks are excluded.
- The destination file is created with owner-only permissions.
- Native CE skill discovery and invocation succeed from the pinned archive. Antigravity authenticated invocation is verified locally under the owner-selected scope in [issue #52](https://github.com/hyperlapse122/dotfiles/issues/52); hosted smoke remains credential-free. Installation, enablement, validation, discovery, and isolated instruction checks remain required on eligible platforms.
- The harness's native skill listing shows each shared user-scope skill exactly once.
- Reapplication restores owned settings and preserves unrelated plugins, credentials, and application state.
- T3 Code loads the native provider and launches its absolute managed executable without relying on the managed binary directory being on `PATH`.
- Direct, concurrent T3, and later direct launches load the same baseline exactly once; only T3 receives its addition. Verify existing instruction settings, quoting, environment precedence, resume, compaction, and mode transitions through native request capture. Keep source inspection, controlled model transports, and authenticated model completion evidence distinct.

Antigravity uses `home/private_dot_gemini/private_empty_GEMINI.md.tmpl` with the explicit `antigravity` identifier. Its apply-always native plugin hooks are `run_after_20-antigravity-plugins.*`; they do not edit native registry files directly.
