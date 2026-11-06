# macOS Setup and Readiness

This guide configures a native Apple Silicon Mac running macOS 26 or later.
Intel Macs, Rosetta-based toolchains, iOS SDKs and Windows-target builds are outside this setup.
Use a normal user account with permission to approve native installers.

## Prepare Native Prerequisites

Install Apple's Command Line Tools interactively and wait for installation to finish:

```sh
xcode-select --install
xcode-select -p
xcrun --find clang
xcrun --show-sdk-path
```

Download the explicit device provisioning script, inspect it, then run it from a native terminal:

```sh
curl -fsSL https://raw.githubusercontent.com/hyperlapse122/dotfiles/main/provision-macos.sh -o /tmp/dotfiles-provision-macos.sh
less /tmp/dotfiles-provision-macos.sh
sh /tmp/dotfiles-provision-macos.sh
```

This operation needs no existing Git, mise or checkout.
It installs Homebrew through its [official installer](https://docs.brew.sh/Installation) when absent, then installs missing Git, mise, standalone chezmoi, GnuPG and pinentry-mac formulae.
The supported Apple Silicon prefix is `/opt/homebrew`; an incompatible existing Homebrew installation requires manual resolution.
Run as your normal user and complete any installer confirmation or administrator password prompts.
If a download or installation fails, resolve the reported problem and rerun; already installed packages are retained without requesting upgrades.
The script does not initialize a checkout, register a chezmoi source, apply personal settings or edit shell startup files.
It is not part of worktree initialization.

Activate Homebrew in the current terminal before the next step:

```sh
eval "$(/opt/homebrew/bin/brew shellenv)"
```

These are prerequisites for obtaining and initializing the repository.
The standalone Homebrew chezmoi registers the permanent source; the repository's mise-installed chezmoi serves source-bound development tasks.
Python, PowerShell, CMake, Ninja, Rust and .NET development versions remain owned by `mise.toml` and `mise.lock`.
Do not install second Homebrew copies of those development tools for this setup.

Configure GPG private-key or hardware-token access before personal application.
The repository does not distribute private GPG keys, establish trust, sign in to accounts, or install organization root certificates.
Use the [Git/GPG guide](../guides/git-and-gpg.md) and [secrets guide](../guides/secrets-and-authentication.md) to confirm the expected `~/.gnupg` location and key access.
Explicit application also restores the existing repository-managed default SSH identity as `~/.ssh/id_ed25519` and `~/.ssh/id_ed25519.pub` after GPG decryption.
Review any existing default SSH identity before previewing and applying, as described in the [SSH identity guide](../guides/secrets-and-authentication.md#ssh-identity).
Never paste tokens or private keys into tracked files or diagnostic output.

## Prepare and Register the Permanent Checkout

Download the repository's macOS entry point, inspect it, then run it:

```sh
curl -fsSL https://raw.githubusercontent.com/hyperlapse122/dotfiles/main/bootstrap.sh -o /tmp/dotfiles-bootstrap.sh
less /tmp/dotfiles-bootstrap.sh
sh /tmp/dotfiles-bootstrap.sh
```

The default checkout is `~/src/github.com/hyperlapse122/dotfiles`.
Pass an absolute destination as the sole argument for another location.
The entry point validates prerequisites, clones or reuses the expected standalone checkout, trusts its mise configuration, runs `mise install`, and explicitly verifies the bootstrap task.
It neither applies personal settings nor registers a global chezmoi source.
An existing checkout is reused without pulling or discarding local changes; update it intentionally when needed.

Register the permanent source as a separate operation:

```sh
cd "$HOME/src/github.com/hyperlapse122/dotfiles"
sh ./configure-chezmoi.sh
```

Registration accepts a standalone repository-root checkout, not a linked worktree.
It preserves compatible TOML configuration and stops on a different registered source or another configuration format rather than migrating it silently.
Source state remains in `home/`, selected by the root `.chezmoiroot`; the destination is the real user home.
Registration does not apply dotfiles.

## Preview and Apply

Close active Claude Code, Codex, omp, Antigravity and T3 sessions before updating their managed configuration and plugins.
From the selected checkout:

```sh
mise exec -- chezmoi --source . diff
mise run apply
```

Preview may require GPG key access to render encrypted destinations.
Explicit application installs missing host apps, configures existing managed files, installs native user-scope CE integrations, and runs `macos-build`.
Host applications include Chrome, 1Password and its CLI; T3 retains its existing installer.
Already-installed host packages are retained without an automatic package upgrade policy.

Podman is not managed or required on macOS.
Application leaves existing Podman installations and VMs untouched, including their running or stopped state.

`macos-build` validates Apple's selected compiler and SDK, installs native .NET 8/10 and Rust through mise, and prepares the pinned writable vcpkg checkout.
It publishes tool roots and Python/PowerShell/CMake/Ninja links under `~/.local/share/dotfiles/build` for use outside a task.
Project manifests, Rust toolchain files, .NET SDK selection and vcpkg libraries remain project-owned.
The same provisioning can be requested explicitly with `mise run macos-build`; ordinary worktree preparation never runs it.

## Open a Fresh Shell

Restart the terminal after application.
The managed PATH fragment is sourced by Bash startup files and Zsh's `.zprofile`/`.zshrc`, honoring `ZDOTDIR`.
For per-project mise activation in Zsh, follow the [mise shell setup instructions](https://mise.jdx.dev/installing-mise.html) and place this line once in the active `.zshrc` if absent:

```sh
eval "$(mise activate zsh)"
```

PowerShell receives its existing managed mise profile integration.
Check discovery in a fresh shell outside the dotfiles directory:

```sh
command -v claude codex omp agy antigravity-acp gh glab ghq t3 op
command -v python pwsh dotnet rustc cargo cmake ninja vcpkg
dotnet --list-sdks
```

If an unrelated executable precedes a managed one, inspect the shell's PATH before proceeding.
PATH integration runs on source changes; an unchanged apply does not repair manually removed shell source lines.

## Inspect Readiness and Complete Runtime Checks

Run the read-only snapshot from the checkout:

```sh
mise exec -- python scripts/macos-readiness.py
mise exec -- python scripts/macos-readiness.py --json
```

Exit `1` means a local check failed; exit `2` means required checks remain pending.
The snapshot checks command and managed-file presence plus selected compiler/SDK inventory.
It never installs, applies, signs in, decrypts secrets, starts a machine, or runs containers and project builds.
Raw command output, tokens and decrypted content are not included in its report.
Manual and runtime rows remain pending by design: complete the checklist below and retain the results separately.
The checker does not import checklist results, so it continues to exit `2` for those pending rows even after the owner has completed and recorded them separately.
A successful installer or a discovered skill alone does not establish full device readiness.

| Capability | Required evidence on this Mac |
| --- | --- |
| Native prerequisites | macOS 26+, native `arm64`, Homebrew `/opt/homebrew`, selected clang and macOS SDK |
| CLI and shells | Commands above resolve in fresh Zsh/Bash and PowerShell sessions outside the repository |
| AI instructions | Claude Code `~/.claude/CLAUDE.md`, Codex `~/.codex/AGENTS.md`, omp `~/.omp/agent/AGENTS.md`, Antigravity `~/.gemini/GEMINI.md` are discovered natively; shared content includes no foreign harness branch |
| CE installation and discovery | Each harness lists/enables the pinned user-scope CE plugin and discovers its native skills; existing disposable-home smoke coverage is described in the testing guide |
| Authenticated CE execution | Sign in through each harness's supported flow and invoke a harmless CE skill; retain the result separately from installation/discovery evidence |
| T3 and desktop apps | `t3 --version`, `t3 app` in a project, managed preferences/provider initialization, Chrome and 1Password launch |
| Git and GPG | Make and verify a representative signed commit in a disposable repository with the intended key; no private key is copied by bootstrap |
| GitHub and GitLab | Verify real intended-account CLI and Git operations after managed Keychain reconciliation; CI fixture credentials prove no real account login |
| Secrets and CA trust | Encrypted destinations apply with the intended GPG key; organization CA is already trusted; a fresh desktop session has `NODE_USE_SYSTEM_CA=1` |
| Native builds | The explicit smoke command below builds, ARM64-identifies and runs Rust, C++, both .NET SDK outputs and a CMake/vcpkg fmt consumer |
| Repeat application | A second `mise run apply` preserves unrelated settings/plugins, keeps commands usable and repairs missing apps |
| New worktree | `mise trust`, `mise install`, and `mise run bootstrap` prepare another worktree without applying personal settings or executing personal chezmoi hooks |
| SSH identity | Review the existing default key before explicit application restores the repository-managed encrypted SSH identity; the former host name records its origin, not a host restriction |
| Platform exclusions | Windows MSVC/MFC/WPF/.NET Framework/SDK provisioning and WSL-specific behavior are not copied to Mac |

Run native build verification explicitly after provisioning:

```sh
python tests/smoke_macos_build_environment.py --report /tmp/dotfiles-native-macos.json
```

The smoke builds in temporary project directories and needs network access for project restores and vcpkg dependencies.
It does not install host toolchains.
CI runs the same smoke with a disposable provisioned home on the `macos-26` ARM64 runner and retains its JSON evidence.
CI does not prove physical key access, GUI approvals, real account login, or authenticated model-backed CE invocation on the owner's Mac.
Do not mark the device fully ready while any required checklist item is failed or pending.

## Maintain Other Worktrees

Keep the registered permanent checkout separate from short-lived feature worktrees.
For development, initialize each worktree with `mise trust` and `mise install`; inspect warnings with `mise run bootstrap`.
Run `mise run apply` only when intentionally applying that worktree's personal configuration.
The source-bound tasks do not change global source registration.
Use `chezmoi update` from the registered permanent source for intentional updates, and review the pending changes before applying them.
