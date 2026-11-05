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

### Test Suite Architecture

| Test Module | Coverage and Assertions |
|---|---|
| `test_bootstrap.py` | Proves `mise install` does not trigger personal chezmoi hooks, mutate personal files, or execute apply scripts. |
| `test_windows_bootstrap.py` | Exercises Windows PowerShell entry points, destination argument parsing, path quoting, OEM encoding, and error propagation. |
| `test_global_chezmoi.py` | Tests chezmoi configuration generation, native pull/apply, and conflict preservation using local Git remotes. |
| `test_git_gpg.py` | Verifies Git configuration rendering, GPG executable detection, and GPG home path safety guards. |
| `test_secrets.py` | Verifies GPG encryption recipient enforcement, ciphertext roundtrip, and fail-closed decryption errors. |
| `test_native_ca_windows.py` | Tests Windows registry writes for `NODE_USE_SYSTEM_CA=1` against disposable registry paths. |
| `test_native_ca_bash.py` | Tests POSIX shell export block appending and idempotent re-application. |
| `test_powershell_profile.py` | Tests profile replacement and mise activation logic across Windows PowerShell and modern PowerShell. |
| `test_windows_apps.py` | Validates WinGet package filtering, `--no-upgrade` flags, and pwsh fallback execution. |
| `test_script_lifecycle.py` | Validates dependency signature invalidation, onchange re-execution, and unchanged-run skipping. |
| `test_personal_apps.py` | Simulates HTTP release asset downloads, SHA-256 validation, and cache reconciliation. |
| `test_harness_plugins.py` | Tests local marketplace registration, force-installation, and auto-update configuration. |

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
| `windows-11-arm` | `windows-arm64` | No | Build verification only |

### Architecture Principles

- **macOS Apple Silicon Only:** macOS CI uses ARM64 (`darwin-arm64`) runners. Intel Macs are not supported.
- **Ubuntu LTS Coverage:** Tracks the two most recent Ubuntu LTS releases (`24.04` and `26.04`) across both x64 and ARM64.
- **Windows Unit Tests:** Executed on x64 runners (`windows-2025`). Windows ARM64 validates artifact compilation without executing unit test suites.
