# Windows Setup and Bootstrap

This guide covers initial bootstrap on a new Windows PC, chezmoi source registration, host application provisioning, native development toolchains, and container runtime prerequisites.

## Prerequisites

- **Operating System:** Windows 10 version 1809 or newer, including Windows 11.
- **Shell:** Windows PowerShell 5.1 or newer (preinstalled with Windows). Git, mise, and modern PowerShell (pwsh) do not need to be installed beforehand.
- **Privileges:** Permission to approve User Account Control (UAC) prompts and package source agreements.
- **Package Manager:** Windows Package Manager (WinGet), provided by Windows App Installer. If WinGet is missing or unregistered, install or update [App Installer from the Microsoft Store](https://apps.microsoft.com/detail/9nblggh4nns1). The bootstrap script requests registration automatically when App Installer is present.
- **Network:** Internet access to download the script, Git, mise, and chezmoi packages.

## Initial PC Bootstrap

The bootstrap script automates prerequisite package installation, repository cloning, and toolchain locking. It does not apply personal home settings, register a global chezmoi source, or alter your user profile.

### 1. Download and Inspect the Script

Start Windows PowerShell (5.1+) and download the bootstrap script to a temporary directory:

```powershell
$bootstrap = Join-Path $env:TEMP 'dotfiles-bootstrap.ps1'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
Invoke-WebRequest -UseBasicParsing 'https://raw.githubusercontent.com/hyperlapse122/dotfiles/main/bootstrap.ps1' -OutFile $bootstrap
notepad $bootstrap
```

Review the contents to verify the actions before execution.

### 2. Run the Bootstrap Script

Run the script in a process-local bypass scope:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $bootstrap
```

> **Security Note:** The `-ExecutionPolicy Bypass` flag applies only to that temporary child process; it does not permanently modify your system or user execution policy. Do not bypass organizational policies if prohibited.

The script performs the following steps:
1. Installs missing Git, mise, and native Windows chezmoi (`twpayne.chezmoi`) using WinGet.
2. Clones this repository to `$HOME\src\github.com\hyperlapse122\dotfiles` (matching standard ghq layout).
3. Executes `mise install` to run the project-level `bootstrap` task through the `postinstall` hook.

To clone into a custom directory, pass `-Destination`:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $bootstrap -Destination 'C:\src\github.com\hyperlapse122\dotfiles'
```

If the destination already exists, it must be a valid clone of `https://github.com/hyperlapse122/dotfiles.git`. The script reuses an existing valid checkout without resetting, pulling, or discarding local changes. Unrelated directories are rejected.

### 3. Register Permanent Chezmoi Source

After bootstrap completes, open a fresh PowerShell window so your environment inherits PATH updates from the installers.

Register the permanent checkout as chezmoi's source:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$HOME\src\github.com\hyperlapse122\dotfiles\configure-chezmoi.ps1"
```

If you specified a custom `-Destination`, supply `-Source 'C:\src\github.com\hyperlapse122\dotfiles'`.

Registration generates or updates chezmoi's persistent TOML configuration, pointing it to the permanent checkout while preserving unrelated configuration. Linked temporary worktrees are rejected. Registration does not apply home files.

## Everyday Operations

After registration, manage dotfiles using native chezmoi from any directory:

```powershell
# Apply current repository configuration to your home directory
chezmoi apply

# Check for remote updates, reinitialize templates, and apply
chezmoi update --apply=false
chezmoi init
chezmoi apply
```

Run `chezmoi init` whenever configuration templates (`.chezmoi.toml.tmpl`) change. This re-evaluates template logic and removes obsolete hooks.

> **Native vs. Mise Chezmoi:** The WinGet-installed Windows executable (`chezmoi.exe`) is for everyday system management. The mise-managed chezmoi copy is isolated for repository development and testing. Outside a mise-activated shell, `Get-Command chezmoi` should point to the native Windows installation.

## Virtualization and Hypervisor Verification

Applying personal settings on Windows executes a pre-apply guard (`.chezmoiscripts/run_before_05-check-windows-prerequisites.ps1.tmpl`) that validates required virtualization features before any files are modified.

The script checks:
- WSL availability via `wsl.exe --version` and `wsl.exe --status`.
- Enabled state of the `VirtualMachinePlatform` Windows optional feature (required by WSL2).
- Enabled state of the `HypervisorPlatform` Windows optional feature (required by this repository's Windows environment).

This check is strictly read-only: it does not enable features, install distributions, or reboot the PC. If prerequisites are missing or disabled, apply stops immediately. Complete the missing features manually in Windows Features, restart Windows if prompted, and rerun apply.

## Windows Host Applications

On Windows, explicit application (`chezmoi apply` or `mise run apply`) installs curated host applications and Python via WinGet.

Package declarations live in `home/.chezmoidata/windows.yaml`:

| Application | WinGet Package ID | Purpose |
|---|---|---|
| Google Chrome | `Google.Chrome` | Primary browser |
| 1Password | `AgileBits.1Password` | Password manager GUI |
| 1Password CLI | `AgileBits.1Password.CLI` | Command-line secrets tool (`op`) |
| PowerShell | `Microsoft.PowerShell` | Modern PowerShell 7 (`pwsh`) |
| Podman Desktop | `RedHat.Podman-Desktop` | Container and Kubernetes GUI |
| T3 Code | `T3Tools.T3Code` | AI coding assistant desktop app |
| Python 3.14 | `Python.Python.3.14` | Default Windows Python for use outside this repository, including node-gyp prerequisites |

Key operational rules:
- WinGet runs with `--no-upgrade`: existing installations (even older versions) are retained. Applications handle their own subsequent updates.
- The installer action runs on change: an unchanged subsequent apply skips package installation and does not reinstall a deliberately removed application.
- After installing 1Password CLI and PowerShell, open a fresh terminal and verify:
  ```powershell
  op --version
  pwsh --version
  ```
- Account logins, browser extensions, and GUI preferences remain manual user actions.

The WinGet-installed Python is separate from the mise-managed Python used for repository development. Project-local mise selections still take precedence in mise-activated shells.

After installing Python, open a fresh PowerShell window in a directory outside this repository and check:

```powershell
Get-Command python
python --version
python -c "import sys; print(sys.executable)"
```

These checks confirm Python discovery and execution, not a complete node-gyp build environment or native addon compatibility.

## Windows Native Build Environment

On Windows x64 hosts, explicit application (`chezmoi apply` or `mise run apply`) invokes `mise run windows-build` from the registered checkout to provision a full C++, .NET, and Rust development environment.

### Installed Components

- **Visual Studio 2026 Build Tools:** Reconciled against `scripts/windows-build-tools.vsconfig` on the stable 2026 channel.
- **C++ Compilers and SDKs:** MSVC v143 and v142 toolsets with ATL/MFC for Win32/x86, x64, and ARM64. Both Windows SDK 10.0.26100.0 and 10.0.22621.0 are installed (v142 ARM64 projects must target SDK 22621 due to header intrinsics).
- **.NET & WPF:** Side-by-side .NET 8 and .NET 10 SDKs (x64 and ARM64), plus .NET Framework 4.8 and 4.8.1 targeting packs.
- **Rust:** Stable `rustc` and `cargo` supporting `x86_64-pc-windows-msvc` and `aarch64-pc-windows-msvc` targets.
- **vcpkg:** Managed checkout at `$HOME\.local\share\dotfiles\vcpkg` with user-wide MSBuild integration.

### Environment and Precedence

Restart your terminal host after apply. The managed PowerShell profile prioritizes `DOTNET_ROOT`, `CARGO_HOME\bin`, and `VCPKG_ROOT` before activating mise, ensuring the native toolchains precede system defaults.

To maintain these build tools independently without running a full dotfiles apply:

```powershell
mise run windows-build
```

To verify the build environment on an existing machine:

```powershell
mise exec chezmoi python -- python tests/smoke_windows_build_environment.py --verify-only
```

This compiles sample C++, MFC, WPF, Rust, and vcpkg projects in temporary workspaces across target architectures.

## Container and Kubernetes Setup (Podman Desktop)

The repository installs Podman Desktop via WinGet, but container engine initialization remains manual.

### Onboarding Steps

1. Launch **Podman Desktop** from the Start Menu.
2. Complete the onboarding wizard to install Podman inside WSL2 and initialize the Podman virtual machine.
   > **Kind on WSL Note:** If running local Kubernetes with kind, configure Podman with rootful machine privileges as documented in [Podman Desktop Kind guidance](https://podman-desktop.io/docs/kind/configuring-podman-for-kind-on-windows).
3. In Podman Desktop Settings, install the Compose and Kubernetes providers (such as kind or Minikube).

### Verification

Open a fresh PowerShell window and check status:

```powershell
podman info
podman compose version
kubectl config get-contexts
$localContext = 'kind-kind-cluster' # Substitute your created context
kubectl --context $localContext cluster-info
kubectl --context $localContext get nodes
```

> **Warning:** Dotfile apply operations never start, stop, reset, or delete Podman machines or Kubernetes clusters. Deleting clusters via Podman Desktop permanently destroys local container workloads and volumes.

### Migration from Rancher Desktop

If migrating from an older Rancher Desktop setup:
1. Run `chezmoi init` to remove legacy WSL2 gate hooks.
2. Once workloads and data are migrated to Podman Desktop, uninstall Rancher Desktop manually through Windows Settings.
