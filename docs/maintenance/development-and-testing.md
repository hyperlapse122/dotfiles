# Development, Testing, and CI

This guide explains how to prepare development worktrees, run the test suite, execute standalone smoke tests, and understand the continuous integration (CI) runner policy.

## Worktree Preparation

Every fresh checkout or git worktree must be prepared using `mise`.

### 1. Authorize Configuration

```sh
mise trust
```

### 2. Install Tools and Run Bootstrap Hook

```sh
mise install
```

`mise install` performs two tasks:
1. Installs all pinned development tools from `mise.toml` and `mise.lock` (including an isolated copy of chezmoi and Python).
2. Executes the project-level `postinstall` hook, which runs the `bootstrap` task.

### Bootstrap Isolation Mechanics

The `bootstrap` task runs:
```sh
chezmoi --config-path .chezmoi-bootstrap.toml --source home managed --exclude=scripts
```

- **Hook-Free Config:** Uses `.chezmoi-bootstrap.toml` to guarantee that personal chezmoi hooks from `~/.config/chezmoi/chezmoi.toml` do not run during repository setup.
- **Read-Only:** Enumerates managed files without applying them or executing lifecycle scripts.
- **Diagnostics:** Mise reports hook failures as warnings and may still exit with code 0. To inspect hook failures with standard exit codes, run:
  ```sh
  mise run bootstrap
  ```

---

## Running Unit Tests

The test suite validates isolation, chezmoi template rendering, script execution guards, and platform integrations using disposable file sandboxes.

Run the entire unit test suite with:

```sh
mise exec -- python -m unittest discover -s tests
```

On Windows, run this command in a standard-user terminal. Installer tests use disposable native doubles, never a real installer or UAC approval. The production installer's legitimate non-admin `RunAs` selection and cancelled-elevation error propagation are tested separately from ordinary verification.

### Independent unit areas

The ownership manifest is `scripts/run-test-area.py`. It validates every discovered test ID before selecting an area. New unassigned modules, duplicate module assignments, duplicate IDs, import errors, or disagreement between discovery and named-module loading fail instead of silently narrowing coverage.

```sh
mise exec -- python scripts/run-test-area.py --validate-only
mise exec -- python scripts/run-test-area.py --area applications
mise exec -- python scripts/run-test-area.py --area security
mise exec -- python scripts/run-test-area.py --area platform
mise exec -- python scripts/run-test-area.py --area build-contracts
mise exec -- python scripts/run-test-area.py --area all --report area-results.json
```

`--list` prints selected IDs without execution. `--report` records elapsed seconds, selected IDs, skipped IDs/reasons, failures, and errors. Keep reports outside the checkout when they are not needed as local artifacts.

| Area | Modules (`tests/`, `.py` suffix omitted) | Prerequisites |
|---|---|---|
| applications | `test_personal_apps`, `test_personal_app_lock`, `test_harness_plugins`, `test_harness_plugin_lock`, `test_t3_code_desktop`, `test_t3_code_settings`, `test_native_ca_shell`, `test_native_ca_windows`, `test_powershell_profile` | Root mise tools, chezmoi, native shell, Bash and PowerShell where available |
| security | `test_secrets`, `test_git_gpg`, `test_script_lifecycle`, `test_github_auth`, `test_github_auth_import`, `test_gitlab_auth`, `test_gitlab_auth_import` | Root mise tools including glab; native GPG/gpgconf, Git, chezmoi, native shell |
| platform | `test_bootstrap`, `test_global_chezmoi`, `test_windows_bootstrap`, `test_windows_apply_hook`, `test_windows_apps`, `test_windows_virtualization` | Root mise tools; Windows PowerShell and Git for Windows fixture checks |
| build-contracts | `test_windows_build_apply`, `test_windows_build_environment`, `test_windows_build_prepare`, `test_windows_build_smoke`, `test_windows_visual_studio`, `test_ci_areas` | Root mise tools; Windows fixture checks use Windows PowerShell and disposable native doubles, never real provisioning |

All areas remain selected on every existing unit runner. Platform guards stay with the tests: Windows-named build-apply/rendering and mocked verifier contracts also run on Unix. The entire tests directory remains importable for credential fixture reuse, but imports do not schedule another area's cases.

The initial three-area candidate put 182 seconds of the measured local baseline in platform contracts, versus about 31 seconds for applications and 63 seconds for security. Four physical areas combine small shell checks with applications and separate build contracts from bootstrap. This reduces the estimated longest local area to about 88 seconds without splitting class fixtures. Hosted setup, queue, and aggregate-runner measurements remain necessary; local estimates do not establish hosted savings.

### Windows Test Console Policy

Run ordinary tests from the invoking terminal; Python subprocesses inherit its console while keeping their existing output capture, timeout, and exit-code handling. Do not add a blanket hidden-window policy to interactive shell checks or native application smoke tests.

The Visual Studio installer tests execute a disposable console executable through a PowerShell `Start-Process` wrapper. That wrapper uses `-NoNewWindow` so nested installer doubles reuse the test console and send stdout/stderr to the captured test diagnostics. A native console-handle assertion checks this inheritance, including installer failure, alongside Unicode output and the existing spaced-path, argument, exit-code, and temporary-download cleanup checks.

This policy applies only to the installer test double. The production installer still selects `RunAs` when required; its UAC/security prompts, cancellation errors, and GUI policy must not be hidden to accommodate tests. Unix/macOS launch behavior is unchanged.

For desktop verification, run the suite from an ordinary Windows terminal and observe extra console windows and focus changes, including nested children. Passing CI tests or inspecting process flags alone does not establish that no window appeared on an interactive desktop.

---

## Standalone Smoke Tests

In addition to unit tests, several standalone smoke scripts test native runtime binaries and credential stores in disposable environments:

### Windows Build Environment

```powershell
# Verify compilers, SDKs, and build outputs on a provisioned PC
mise exec chezmoi python -- python tests/smoke_windows_build_environment.py --verify-only
```

Run verification in a non-elevated Windows x64 terminal after preparing the intended user's environment. The command prints the observed token elevation state and refuses an elevated session. Its read-only preflight fails before compilation when required tools, targets, SDKs, or user-wide integration are missing; it never installs them or requests elevation.

Machine preparation is a different operation:

```powershell
# Explicit preparation of the intended user's environment; first VS install may elevate
mise run windows-build

# Preparation-only opt-in for a disposable GitHub-hosted Windows x64 runner
mise exec chezmoi python -- python tests/prepare_windows_build_environment.py --provision
```

The verifier no longer accepts `--provision`. The separate helper prepares twice and stops on failure without running builds or claiming standard-user readiness. Default CI jobs remain free of privileged preparation. A future dedicated real-build CI lane must use a prepared environment and record a non-elevated verification token; its restoration and hosted preparation diagnosis remain [#39](https://github.com/hyperlapse122/dotfiles/issues/39).

Ready existing VS 2026 Build Tools installations are reused without download or servicing. Existing incomplete/unhealthy installations or missing components require manual Visual Studio Installer maintenance; automatic update/repair/reconciliation is not part of apply. See [Windows build setup](../setup/windows.md#windows-native-build-environment) for the inventory, first-install safeguards, and full matrix.

Compiles sample C++, MFC, WPF, Rust, and vcpkg targets in temporary directories.

### T3 Code Desktop and ACP

```sh
mise exec -- python tests/smoke_t3_code.py
```

Tests bundled CLI launcher discovery and ACP initialize handshakes.

### Personal CLI Applications

```sh
# Run pinned personal binaries in an isolated sandbox
mise exec -- python tests/smoke_personal_apps.py
```

Tests actual `omp`, `gh`, and `ghq` binaries. CI runs with `--path-integration` to verify shell PATH inheritance.

### Harness Plugins

```sh
mise exec -- python tests/smoke_harness_plugins.py
```

Tests native skill URI resolution and local marketplace registration in an isolated temporary home.

### GitLab Authentication

```sh
mise exec -- python tests/smoke_gitlab_auth.py
```

Exercises native credential store integration and Git credential helper routing using synthetic GitLab accounts.

---

## CI Runner Policy

CI workflows in `.github/workflows/test.yml` run unit and native smoke checks across supported operating systems.

### Runner Matrix

| Runner Label | Target Platform | Unit Tests | Native Smoke Tests |
|---|---|---|---|
| `ubuntu-24.04` | `linux-amd64` | Yes | Yes |
| `ubuntu-24.04-arm` | `linux-arm64` | Yes | Yes |
| `ubuntu-26.04` | `linux-amd64` | Yes | Yes |
| `ubuntu-26.04-arm` | `linux-arm64` | Yes | Yes |
| `xcode-27` | `darwin-arm64` | Yes | Yes |
| `windows-2025` | `windows-amd64` | Yes | Yes |
| `windows-11-arm` | `windows-arm64` | No | All five native smoke areas |

### Architecture Principles

- **macOS Apple Silicon Only:** macOS CI uses ARM64 (`darwin-arm64`) runners. Intel Macs are not supported.
- **Ubuntu LTS Coverage:** Tracks the two most recent Ubuntu LTS releases (`24.04` and `26.04`) across both x64 and ARM64.
- **Windows unit tests:** Run on x64 (`windows-2025`). Windows ARM64 executes all five native smoke areas; this is not an ARM64 build-only lane.

### Native areas and independent setup

Each area/target pair owns a separate hosted runner. All matrices use `fail-fast: false`, so an area's failure cannot suppress unrelated results. Jobs time out after 20 minutes; apps and CE steps have 10-minute limits, T3 15 minutes, and credential execution 5 minutes.

| Area | Invocation after tool preparation | Job-owned prerequisites |
|---|---|---|
| apps | `mise exec chezmoi python -- python tests/smoke_personal_apps.py --path-integration --expected-target TARGET` | Pinned apps and disposable PATH/profile fixture |
| t3 | `mise exec chezmoi python gh -- python tests/smoke_t3_code.py --install-desktop --expected-target TARGET` | Native desktop installation, pinned omp acquisition, scoped GitHub token |
| ce | `mise exec chezmoi python -- python tests/smoke_harness_plugins.py --expected-target TARGET` | Isolated pinned omp/CE payload and harness state |
| github-auth | `mise exec chezmoi python uv pipx:keyring -- python tests/smoke_github_auth.py` | Native GPG, pinned gh acquired by fixture, OS credential backend |
| gitlab-auth | `mise exec chezmoi python uv pipx:keyring -- python tests/smoke_gitlab_auth.py` | Native GPG, pinned glab acquired by fixture, OS credential backend |

Hosted-only PATH, desktop-installation, and credential-write modes must not run on a personal workstation. Their existing disposable-host guards remain intact. The apps and desktop scripts offer non-installing local modes as described above; CE uses a disposable home.

Windows credential jobs verify and unpack the existing checksummed native GPG fixture; Git's MSYS GPG is not a substitute. Each Linux credential job provisions and starts its own D-Bus/Secret Service session. macOS credential fixtures restore the original default keychain and search list. Windows ARM installs only the tools needed by its area, not the unsupported full development tool set.

Unit jobs retain the root mise tool environment because the bootstrap contract runs ordinary `mise install` twice. Each unit job validates the entire assignment map and uploads its test-ID/skip/timing report, even though it executes only one area.
