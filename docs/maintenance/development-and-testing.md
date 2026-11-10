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
chezmoi --config .chezmoi-bootstrap.toml --source . managed --exclude=scripts
```

- **Hook-Free Config:** Uses `.chezmoi-bootstrap.toml` to guarantee that personal chezmoi hooks from `~/.config/chezmoi/chezmoi.toml` do not run during repository setup.
- **Read-Only:** Enumerates managed files without applying them or executing lifecycle scripts.
- **Asset Isolation:** Archive declarations are preparation templates, so bootstrap does not download or extract personal assets. Explicit apply prepares them before native consumers; see [external asset preparation](chezmoi-source.md#external-asset-preparation).
- **Diagnostics:** Mise reports hook failures as warnings and may still exit with code 0. To inspect hook failures with standard exit codes, run:
  ```sh
  mise run bootstrap
  ```

---

## Running Unit Tests

The test suite validates isolation, chezmoi template rendering, script execution guards, and platform integrations using disposable file sandboxes.

External-asset fixtures use local HTTP archives and the real native chezmoi preparation command.
They cover cold and unchanged runs, missing-file repair, changed pins, checksum failures, exact owned-directory cleanup, and explicit full verification.
Selective application fixtures prepare assets separately while keeping unrelated scripts excluded, so a Windows fixture does not enable persistent PATH or registry configuration.

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

| Area | Coverage | Prerequisites |
|---|---|---|
| applications | Application/model pins, shared asset preparation, fonts, harnesses, T3 settings, shell profiles and completions | Root mise tools, chezmoi, native shell, Bash and PowerShell where available |
| security | Encrypted inputs, Git/GPG, pinentry application, SSH identities, scoped CA files, GitHub/GitLab and registry authentication | Root mise tools including glab; native GPG/gpgconf, Git, chezmoi, native shell |
| platform | Worktree/bootstrap guards, OS provisioning/readiness, Ghostty and terminal integration | Root mise tools; Windows PowerShell and Git for Windows fixture checks; Bash for isolated macOS command doubles |
| build-contracts | Windows/macOS/Linux build contracts, exact test ownership and CI event policy | Root mise tools; Windows fixture checks use Windows PowerShell and disposable native doubles |

The manifest contains the complete module assignment. `--list` exposes the current test IDs for each area.

All areas remain selected on every existing unit runner. Platform guards stay with the tests: Windows-named build-apply/rendering and mocked verifier contracts also run on Unix. The entire tests directory remains importable for credential fixture reuse, but imports do not schedule another area's cases.

The initial three-area candidate put 182 seconds of the measured local baseline in platform contracts, versus about 31 seconds for applications and 63 seconds for security. Four physical areas combine small shell checks with applications and separate build contracts from bootstrap. This reduces the estimated longest local area to about 88 seconds without splitting class fixtures. Hosted setup, queue, and aggregate-runner measurements remain necessary; local estimates do not establish hosted savings.

The first actual selected-area run passed 226 cases with the baseline's 10 platform skips: applications 56.165s, security 63.524s, platform 108.185s, and build-contracts 69.160s. The platform run exceeded the additive estimate, which reinforces the need to measure full jobs rather than infer savings from summed test timings.

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

The verifier no longer accepts `--provision`. The separate helper prepares twice and stops on failure without running builds or claiming standard-user readiness. Default CI jobs remain free of privileged preparation. [#39](https://github.com/hyperlapse122/dotfiles/issues/39) was closed as not planned; this change does not restore a dedicated real-build CI lane or diagnose hosted provisioning.

Ready existing VS 2026 Build Tools installations are reused without download or servicing. Existing incomplete/unhealthy installations or missing components require manual Visual Studio Installer maintenance; automatic update/repair/reconciliation is not part of apply. See [Windows build setup](../setup/windows.md#windows-native-build-environment) for the inventory, first-install safeguards, and full matrix.

Compiles sample C++, MFC, WPF, Rust, and vcpkg targets in temporary directories.

### T3 Code Desktop and Harnesses

```sh
mise exec -- python tests/smoke_t3_code.py
```

Tests bundled CLI discovery, retired omp provider removal, native Codex app-server initialization, and Claude SDK initialization with pinned CE command discovery. Fresh T3 servers launch the managed binaries with their directory absent from `PATH`.

### Personal CLI Applications

```sh
# Run pinned personal binaries in an isolated sandbox
mise exec -- python tests/smoke_personal_apps.py
```

Tests actual Claude Code, Codex, `gh`, `ghq`, and `glab` binaries. CI runs with `--path-integration` to verify shell PATH inheritance.

### User Fonts

```sh
mise exec -- python -m unittest discover -s tests -p 'test_font*.py'
mise exec -- python tests/smoke_fonts.py
```

Unit tests use local archive fixtures to verify lock generation and real chezmoi staging, then exercise native repair and owned-file cleanup in disposable paths.
The smoke downloads the pinned collection, gives each package a unique test prefix, and verifies repeat application and actual OS discovery: fontconfig on Linux, CoreText on macOS, and fresh-process WPF enumeration plus HKCU persistence on Windows.
It never applies the personal source.

Windows cleanup removes the smoke's registry entries and session resources before deleting its files.
If another Windows session keeps a temporary font file locked, the smoke reports its location; the file can remain until that session releases it.
No service stop, elevation, or reboot is automated.
Use `--asset-cache <directory>` to serve already-downloaded official archives from a local HTTP fixture while retaining checksum verification.

### Harness Plugins

```sh
mise exec -- python tests/smoke_harness_plugins.py
```

Tests native skill URI resolution and local marketplace registration in an isolated temporary home.

### Codex Native Instructions and CE

```sh
mise exec -- python tests/smoke_codex.py
```

Tests the complete pinned package, private user-scope instructions, native CE installation and reconciliation, and explicit skill expansion into an outgoing model request. A capture-only localhost endpoint rejects the request; the smoke does not use personal credentials or exercise authenticated model completion.

### Claude Native Preferences, Instructions, and CE

```sh
mise exec -- python tests/smoke_claude.py
```

Tests the pinned native executable, user-scope CE discovery and repair, private preferences, and shared instructions in a disposable home. Outgoing requests must include the Korean preference and complete explicitly invoked CE skill body, include common and Claude instruction markers, and exclude foreign branches. An enabled automatic-memory characterization first proves that the fixture is readable; the managed disabled state must exclude it while preserving its bytes. A localhost capture endpoint returns HTTP 400; only inert credentials are used, and authenticated inference is outside this smoke.

### Pi and Grok Native Integration

```sh
mise exec chezmoi python -- python tests/smoke_pi.py --t3
mise exec chezmoi python -- python tests/smoke_grok.py --t3
```

Both smokes prepare official pinned artifacts in disposable homes, repair native CE registration, capture expanded skill requests, and initialize their native T3 drivers with managed binary directories absent from `PATH`. Pi additionally verifies the exact locked Synthetic catalog, foreign-provider blocking, reload, removed saved selections, and missing credentials/policy. T3 checks require native discovery metadata so a version-only fallback cannot pass.

These inference requests use inert credentials and rejecting loopback endpoints. Native validation jobs receive no Synthetic secret; only the model-discovery resolver step uses the repository Actions secret. Hosted CI uses `--install-desktop` to provision its own T3 prerequisite.

The separate T3 instruction smoke uses controlled local model replies to exercise native context selection, resume, compaction and mode transitions. It checks existing instruction settings, per-provider environment precedence, CE invocation, and isolation from concurrent or later direct CLI processes. Codex and Claude checks also inspect native spawning tool removal while retaining named T3 delegation tools across fresh turns, mode changes, resume, and compaction. Repeat `--harness codex --harness claude` to run only those harnesses; the default still includes pi. The Grok smoke captures an actual T3 request and compares its spawning tools with direct CLI requests before and after the T3 launch.

```sh
mise exec chezmoi python -- python tests/smoke_t3_instructions.py
```

### Registry Credentials

```sh
mise run container-auth:smoke
```

This hosted-only smoke exercises official native credential helpers and the declared Podman client. The Podman connection fixture answers only the startup ping; credential lookup uses the actual host-side client and native store. It creates no container engine or VM. Each supported runner owns its credential fixture and cleanup.

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
| `ubuntu-24.04` hosting the container image `registry.fedoraproject.org/fedora:45` | `linux-amd64` | Yes | CLI compatibility only |
| `macos-26` | `darwin-arm64` | Yes | Yes |
| `windows-2025` | `windows-amd64` | Yes | Yes |
| `windows-11-arm` | `windows-arm64` | No | All Windows-eligible native smoke areas |

### Architecture Principles

- **macOS Apple Silicon Only:** macOS CI uses ARM64 (`darwin-arm64`) runners. Intel Macs are not supported.
- **Linux lanes run in a Fedora image:** The Linux unit, native and pinentry lanes run on amd64 only, as container jobs in `registry.fedoraproject.org/fedora:45`. GitHub hosts no Fedora runner, so each job keeps the `ubuntu-24.04` runner label as the container host and every step runs inside the Fedora image. The image tag equals the validated release in `scripts/linux-platform.py`, and a contract test keeps the two together. There is no Linux arm64 lane and no Ubuntu 26.04 lane.
- **The Fedora image is not a workstation:** Workstation support is native Fedora KDE Plasma Desktop on amd64. The image reports `VARIANT_ID=container`, so the host probe rejects it, and no CI result certifies workstation acceptance.
- **Lock-update workflows keep Ubuntu runners:** The font, harness plugin and personal application updaters run automation, not Linux workstation tests, so they stay on hosted Ubuntu runners.
- **Windows unit tests:** Run on x64 (`windows-2025`). Windows ARM64 executes all Windows-eligible native smoke areas; this is not an ARM64 build-only lane.

### Native areas and independent setup

The Linux lanes exclude Ghostty and the desktop-backed T3/instruction areas because the Fedora image is not a KDE Plasma Desktop installation and the host probe rejects it.
Pi and Grok retain their direct CLI/native CE checks on Linux without installing T3; desktop-backed checks remain on the existing eligible Windows/macOS runners.
Antigravity runs in its own area so its Linux CLI and native CE proof do not depend on a desktop-only lane.
Fedora KDE desktop, native build and minikube acceptance remain the separate explicit checks in the [Fedora setup guide](../setup/fedora.md); no CI result certifies those checks.

The separate **Native macOS ARM64 builds** job explicitly runs `mise run macos-build` with a disposable home and job-owned mise data/cache roots.
Its provisioning process clears inherited .NET/Rust roots so a runner's preinstalled environment cannot redirect installation into the runner account's tool roots.
It then runs `tests/smoke_macos_build_environment.py --home` against that provisioned home and retains `native-macos-build.json`.
This 45-minute job compiles, ARM64-identifies and runs Rust, C++, .NET 8/10 apphosts and a CMake project consuming vcpkg fmt; it also checks the shared PATH fragment from a fresh shell.
It reuses immutable checkout and candidate-pin selection and does not apply the owner's dotfiles or run real account authentication.
For an intentionally provisioned local Mac, use the [macOS setup guide](../setup/macos.md) for the explicit smoke command and manual readiness checklist.

Each area/target pair owns a separate hosted runner. All matrices use `fail-fast: false`, so an area's failure cannot suppress unrelated results. Jobs time out after 20 minutes; apps, CE, Codex, and Claude steps have 10-minute limits, T3 15 minutes, and credential execution 5 minutes.

| Area | Invocation after tool preparation | Job-owned prerequisites |
|---|---|---|
| apps | `mise exec chezmoi python -- python tests/smoke_personal_apps.py --path-integration --expected-target TARGET` | Pinned apps and disposable PATH/profile fixture |
| t3 | `mise exec chezmoi python gh -- python tests/smoke_t3_code.py --install-desktop --expected-target TARGET` | Native desktop installation, pinned Codex/Claude and CE acquisition, scoped GitHub token |
| antigravity | `mise exec chezmoi python -- python tests/smoke_antigravity.py --expected-target TARGET` | Pinned native CLI and CE with isolated provider settings |
| t3-instructions | `mise exec chezmoi python gh -- python tests/smoke_t3_instructions.py --install-desktop --expected-target TARGET` | Pinned Codex/Claude/Pi, native CE, controlled local model transport and disposable T3 lifecycle fixtures |
| ce | `mise exec chezmoi python -- python tests/smoke_harness_plugins.py --expected-target TARGET` | Isolated shared CE acquisition and integrity checks |
| codex | `mise exec chezmoi python -- python tests/smoke_codex.py --expected-target TARGET` | Complete pinned Codex package and isolated native CE state |
| claude | `mise exec chezmoi python -- python tests/smoke_claude.py --expected-target TARGET` | Pinned Claude binary and isolated native CE, instruction, preference, and memory fixtures |
| pi | `mise exec chezmoi python gh -- python tests/smoke_pi.py --expected-target TARGET` plus `--install-desktop` on Windows/macOS | Complete pinned Pi distribution, Synthetic model lock and native CE; eligible hosts also prove T3 |
| grok | `mise exec chezmoi python gh -- python tests/smoke_grok.py --expected-target TARGET` plus `--install-desktop` on Windows/macOS | Pinned Grok and native CE; eligible hosts also prove T3 ACP |
| github-auth | `mise exec chezmoi python uv pipx:keyring -- python tests/smoke_github_auth.py` | Native GPG, pinned gh acquired by fixture, OS credential backend |
| gitlab-auth | `mise exec chezmoi python uv pipx:keyring -- python tests/smoke_gitlab_auth.py` | Native GPG, pinned glab acquired by fixture, OS credential backend |
| container-auth | `mise exec chezmoi python podman@6.1.4 -- python tests/smoke_container_auth.py --require-podman` | Official credential helper, declared host-side Podman client and isolated native credential store |
| fonts | `mise exec chezmoi python -- python tests/smoke_fonts.py` | Pinned font assets and native OS font discovery |

The independent pinentry job runs workspace formatting, clippy, locked Rust tests, a native release build, generated shell completion checks, and hosted native PIN-store verification. Its tool preparation includes Usage and PowerShell for completion generation.

Application-lock candidates contain both `personal-app-lock.json` and `synthetic-model-lock.json`. The automatic updater publishes that immutable pair after generation without running the validation suite. Synthetic discovery failure retains the previous pair and fails the update job. When the reusable Test workflow is invoked with a candidate, the Pi native job exercises the candidate binary against the candidate catalog.

Hosted-only PATH, desktop-installation, and credential-write modes must not run on a personal workstation. Their existing disposable-host guards remain intact. The apps and desktop scripts offer non-installing local modes as described above; CE, Codex, and Claude use disposable homes. Claude and T3 native startup have passed locally on Windows x64. Other eligible platforms require their own CI result; local request capture and initialization do not prove authenticated model completion.

Windows credential jobs verify and unpack the existing checksummed native GPG fixture; Git's MSYS GPG is not a substitute. Each Linux credential job provisions and starts its own D-Bus/Secret Service session. macOS credential fixtures restore the original default keychain and search list. Windows ARM installs only the tools needed by its area, not the unsupported full development tool set.

Unit jobs retain the root mise tool environment because the bootstrap contract runs ordinary `mise install` twice. Each unit job validates the entire assignment map and uploads its test-ID/skip/timing report, even though it executes only one area.

### Ghostty native verification

The `ghostty` native smoke supports Fedora KDE Plasma Desktop amd64 and Apple Silicon macOS; it is excluded from Windows and from the Linux CI lane, whose Fedora image is not a KDE Plasma Desktop host. A CI result must not be reported as native Fedora KDE acceptance, regardless of the CI matrix label.
It executes `mise exec chezmoi python -- python tests/smoke_ghostty.py` on disposable machines.
The smoke verifies actual package installation and version discovery, the KDE terminal selection keys in `kdeglobals` and the Ghostty desktop metadata, a disposable Fedora account's shell change, and macOS helper compilation and read-only association lookup.
It does not change the runner owner's login shell or macOS default-app association.

The platform unit area owns `test_ghostty_install` and `test_terminal_environment`.
Those fixtures use isolated command doubles for account, package, and default-app operations: changing HOME alone cannot isolate `chsh`, `kwriteconfig6`, or LaunchServices.
Use focused unittest discovery for these modules before the broader platform area.
Native smoke evidence supplements those fixtures; mocked Swift or shell commands do not prove native API compatibility.

Actual desktop launch, macOS approval, and current-directory forwarding with an existing Ghostty instance remain the [terminal guide's desktop checklist](../guides/terminal.md#desktop-acceptance-checklist).
Do not describe a passing headless smoke or a selected desktop ID as proof that those GUI checks passed.

### Automatic events

`test.yml` directly handles unfiltered `push` and `pull_request` events alongside its existing manual and reusable interfaces. The former `Test events` admission workflow and its metadata policy are removed. There is no conditional `Validate` reusable-call wrapper to leave a redundant skipped check.

| Event | Validation |
|---|---|
| Any branch push, including the default branch | Event branch-head suite |
| Tag push | Event tag suite |
| PR opened, updated or reopened, including fork PRs | Event merge-result suite when GitHub can create the merge result |
| Conflicted PR | GitHub does not schedule a `pull_request` run; the branch push suite remains available |
| Manual dispatch | Independent suite with optional immutable checkout and candidate-artifact inputs |
| Reusable call | Independent caller-owned suite with its existing input identity |

Every suite checkout retains `${{ inputs.base-sha || github.sha }}` with nonpersistent credentials. Automatic PR validation uses the event's immutable merge SHA. Manual and reusable Test entry points retain their candidate-artifact interfaces.

The font, harness plugin, and personal application updaters publish generated candidates without invoking Test or waiting for CI validation. Publication still uses the resolver's immutable base SHA and artifact ID, commits only changed generated locks, and reports generation or push failures normally. The bot's GITHUB_TOKEN pushes do not start push workflows, so publication does not automatically schedule a replacement Test run. Problems discovered afterward are handled separately. The harness updater's separate shared-skill drift report remains active and can fail the run even when plugin pins have been published.

Push and PR suites are independent. A same-repository PR branch can run both suites for one update; this duplicate runner cost is the deliberate tradeoff for removing admission while preserving branch and merge-result coverage. There is no PR metadata lookup, superseded-head suppression, workflow cancellation, or Actions write permission. A fork's branch-push validation depends on Actions being enabled in that fork; the base repository still handles eligible fork PR events under GitHub's normal approval rules. Base-only advancement does not by itself schedule a new PR event.

The direct-workflow contracts in `tests/test_ci_workflows.py` cover unfiltered automatic triggers, retained manual/reusable entry points and checkout/artifact selection, read-only permissions, and removal of the conditional wrapper. Existing candidate-lock and matrix contracts remain in `tests/test_ci_areas.py`. Record current-head hosted push/PR run URLs and outcomes after publication; the historical measurements below describe the earlier topology.

### Check names

Automatic jobs now report directly under `Test`, without the `Validate /` reusable-call prefix. Their names remain `Unit AREA (RUNNER)` and `Native AREA (RUNNER, TARGET)`; the existing build and control jobs remain intact. Reusable callers can still add their own caller prefix.

Repository protection settings are not modified by this change. If a ruleset requires a former `Validate / ...` context, update it to the corresponding direct `Test` job context before merging. Admission-only checks never prove that the suite passed.

### Hosted measurements

These measurements predate the Fedora image. The Linux jobs they count ran on hosted Ubuntu 24.04 and 26.04 runners, on amd64 and arm64, so the job counts and the six-platform figures below describe that earlier matrix, not the current one.

The baseline pair used `86ae6829b0bf1f0f194724196d34cb34f6643040`; the first independent-area run used PR head `c609cbd2fed8f545311aff7491e647ac18926504`. Elapsed time runs from workflow creation to the final job completion. Aggregate runner time sums job start/end durations, including setup and cleanup but excluding queue time and billing rounding.

| Run | Outcome | Jobs | Elapsed | Aggregate runner time |
|---|---|---:|---:|---:|
| [Baseline PR](https://github.com/hyperlapse122/dotfiles/actions/runs/41959406936) | Success | 13 | 309s | 1532s |
| [Baseline push](https://github.com/hyperlapse122/dotfiles/actions/runs/41959146646) | Success | 13 | 283s | 1599s |
| [Independent-area PR](https://github.com/hyperlapse122/dotfiles/actions/runs/41966823335) | Success | 61 | 197s | 2759s |
| [PR-open push overlap](https://github.com/hyperlapse122/dotfiles/actions/runs/41966778441) | Canceled by PR controller | 61 | 133s | 2347s |

The independent-area PR passed all 24 unit jobs, 35 native jobs, and two control jobs. The longest job was Windows ARM64 CE at 136s; all five Windows ARM64 native areas passed. The last job started 131s after workflow creation, so the elapsed result includes scheduling and queue effects. Runner timestamps do not isolate queue delay from admission or dependency delay.

The 24 unit-report artifacts select the same 236 IDs on all six platforms, exactly once across each platform's four areas. This is the original 220 cases, 15 new CI contracts, and the Developer Mode bootstrap case merged into main independently. Windows retained nine hosted skips. Linux and macOS have one additional skipped case because that new bootstrap case is Windows-only.

Parallel setup reduced this PR's elapsed time but increased its aggregate runner time. The initial push/PR handoff consumed 5106 runner-seconds including canceled work, versus 3131 for the baseline duplicate pair. Do not claim that the opening race saves runner time. Ordinary PR-update admission must be assessed separately from that race.

## Fedora Inspection and Native Proof

Linux workstation support targets the native dnf-based Fedora KDE Plasma Desktop edition on amd64, at the validated release 45 or later. CI in the Fedora image can provide fixture evidence but cannot certify the Plasma desktop, hardware, credentials or daily work. The [setup guide](../setup/fedora.md) records the macOS capability inventory, vendor limitations and owner acceptance steps.

`python3 scripts/linux-readiness.py --json` is read-only inspection. Exit `1` reports missing prerequisites or an unsupported host; `2` reports pending native checks; `0` requires all checks to pass. It uses the shared host probe, PATH/file presence and fixed package-inventory queries. It does not execute harnesses, Podman or the `docker` command, query secret storage, authenticate, decrypt, start services or create clusters. It publishes fixed diagnostics rather than command output. Native checks remain pending even with all installation fixtures present; there is no acceptance override.

Run its focused fixtures with the prepared repository tools:

```sh
mise exec -- python -m unittest discover -s tests -p test_linux_readiness.py
```

These fixtures cover the read-only command allowlist, sanitized/bounded JSON, unsupported release/edition/architecture, a newer release reported as not yet validated, missing prerequisites and pending native acceptance. They do not prove that packages launch or credentials work.

After explicit host application, `mise run linux-build` installs and publishes native build tools, and `mise run linux-kubernetes` publishes minikube/kubectl without starting either runtime or cluster. From a fresh external-directory login shell, run `python3 /absolute/checkout/tests/smoke_linux_build_environment.py --home "$HOME" --report /tmp/dotfiles-linux-build.json`. Require successful native compilation and execution, including vcpkg dependency resolution. This is separate from default inspection and ordinary worktree preparation.

`python3 tests/smoke_linux_minikube.py --report /tmp/dotfiles-linux-minikube.json` is an explicit, runtime-starting native proof. It runs minikube on rootless Podman with private Podman storage, run state and network configuration and isolated minikube/kubeconfig state; it builds/runs an image, deploys a workload, verifies host HTTP access and deletes the cluster and task resources. Exit codes are `0` passed, `1` failed/interrupted, `2` unavailable, and `3` cleanup incomplete. Check the report's cleanup result and empty remaining-resource inventories, including volumes, independently of workload success. It exits `2` when the `cpu`, `memory` or `pids` cgroup controller is not delegated to the user session; the setup guide gives the owner-approved fix. When the proof cannot pass on rootless Podman, record minikube as an unresolved limitation; no other runtime is installed. After forced interruption, recover only its reported profile, storage root and state paths; never prune or reset shared Podman storage. Measure host disk reclamation separately. Keep native evidence pending when the target host is unavailable.

Shared worktree preparation continues to use the hook-free bootstrap configuration and must not apply personal state. Native tests that install packages or write credentials belong on eligible disposable hosts; fixture tests on macOS are not a workstation-readiness certificate.
