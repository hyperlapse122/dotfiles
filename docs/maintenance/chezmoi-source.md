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
    ├── .chezmoiexternals/  # Declarative external archives and downloads
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

> **Note:** Filenames in `.chezmoidata/` do not create namespaces in chezmoi. Ensure top-level dictionary keys remain unique across files.

---

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
`home/.chezmoiexternals/fonts.toml.tmpl` stages only selected archive members; `font-index.tsv` supplies their member hashes to the native installers.
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

## Shared User-Scope Harness Onboarding

All AI harnesses managed by this repository must connect their user-scope instructions to a single shared template.

### 1. The Shared Instruction Template

`home/.chezmoitemplates/agent-instructions` contains:
- Common instructions shared across all AI agents.
- Conditional blocks for harness-specific logic:
  ```gotemplate
  {{ if eq .harness "omp" }}
  # omp-specific instructions
  {{ end }}
  ```

### 2. Adding a New Harness Adapter

To onboard a new harness (e.g. `example-harness`):
1. Identify the harness's documented user-scope instruction file (e.g. `~/.config/example/AGENTS.md`).
2. Add a thin template adapter in `home/` at the matching relative path (e.g. `home/private_dot_config/private_example/private_empty_AGENTS.md.tmpl`).
3. Pass the harness identifier and chezmoi context into the shared template:
   ```gotemplate
   {{- template "agent-instructions" (dict "harness" "example" "chezmoi" .) -}}
   ```
4. Register, install, and enable the repository-pinned Compound Engineering plugin through the harness's native user-scope mechanism. Codex uses native `plugin marketplace add` and `plugin add`; Claude uses `plugin marketplace add`, `plugin install`, and `plugin enable` with `--scope user`; omp uses its own marketplace/install/enable commands. Antigravity uses its supported native plugin commands. Reuse the existing release/commit pin, preserve unrelated plugins and settings, and install only during explicit apply.

Claude's adapter is `home/private_dot_claude/private_empty_CLAUDE.md.tmpl`, targeting `~/.claude/CLAUDE.md` with `harness = claude`. Its private settings merge and after hooks preserve unrelated state. The POSIX hook parses native JSON through the invoking chezmoi executable with a hook-free config; it does not assume Python or jq can be resolved outside the worktree.

### 3. Verification

Verify in a disposable sandbox:
- The common instructions are included.
- Foreign harness conditional blocks are excluded.
- The destination file is created with owner-only permissions.
- Native CE skill discovery and invocation succeed from the pinned archive. Antigravity's authenticated invocation is deferred to [issue #52](https://github.com/hyperlapse122/dotfiles/issues/52); its installation, enablement, validation, and discovery remain required.
- Reapplication restores owned settings and preserves unrelated plugins, credentials, and application state.
- T3 Code loads the native provider and launches its absolute managed executable without relying on the managed binary directory being on `PATH`.

Antigravity uses `home/private_dot_gemini/private_empty_GEMINI.md.tmpl` with the explicit `antigravity` identifier. Its apply-always native plugin hooks are `run_after_20-antigravity-plugins.*`; they do not edit native registry files directly.
