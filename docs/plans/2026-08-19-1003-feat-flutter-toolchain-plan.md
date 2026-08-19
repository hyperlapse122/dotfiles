---
title: Add Flutter Toolchain and Development Environments - Plan
type: feat
date: 2026-08-19
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
execution: code
product_contract_source: ce-brainstorm
---

# Add Flutter Toolchain and Development Environments - Plan

## Goal Capsule

- **Objective:** Flutter SDK and complete platform development toolchains (Linux: Android, Web, Linux desktop; macOS: Android, Web, macOS, iOS) are installed and configured cleanly across managed hosts.
- **Means:** Versioned archive delivery in `~/.local/share/flutter/versions/<tag>` via `release-lock` / `.chezmoiexternals/dev-tools.toml`, symlinking all binaries to `~/.local/bin`, system build dependencies declared in `.chezmoidata/packages.yaml`, and automated Android SDK CLI provisioning.
- **Authority:** User direction ("(지금은 없지만) `codex`가 설치되었던 구조와 동일하거나 유사한 구조로 설치... Linux에선 android, web, linux, macOS에선 Android, web, macOS, iOS") + official Flutter platform documentation.
- **Open blockers:** None.

---

## Product Contract

### Summary

Add Flutter SDK management to dotfiles using an XDG-compliant, versioned archive delivery model (`~/.local/share/flutter/versions/<tag>` with `~/.local/share/flutter/current` and `~/.local/bin` symlinks). Automatically provision required system build packages for Linux desktop, macOS desktop/iOS, and Web targets, and automate Android SDK command-line tools and environment setup (`~/.local/share/android-sdk`, `ANDROID_HOME`, `JAVA_HOME`, `sdkmanager` packages, licenses).

### Problem Frame

Flutter and its cross-platform toolchains require diverse platform-specific dependencies (Linux desktop C++ libraries, Xcode CLI/CocoaPods for Apple targets, JDK & Android SDK command-line tools for Android, Chromium for Web). Ad-hoc installations cause path drift, version conflicts, and missing build dependencies across machines. Managing Flutter via chezmoi externals, static release locks, and declarative package manifests provides idempotent, reproducible environments on both Linux and macOS.

### Requirements

**Flutter SDK Delivery & Versioning**

- R1. The Flutter SDK archive is defined in `packages/release-lock` and `.chezmoiexternals/dev-tools.toml`, extracting versioned releases into `~/.local/share/flutter/versions/<tag>`.
- R2. A dedicated `00-tools` script (`run_onchange_after_flutter.sh.tmpl`) manages the `~/.local/share/flutter/current` symlink, symlinks all executables in `current/bin/` (`flutter`, `dart`) into `~/.local/bin/`, and prunes older versions.

**Linux Platform Toolchain (Android, Web, Linux Desktop)**

- R3. Linux desktop build prerequisites (`clang`, `cmake`, `ninja-build`, `pkgconfig`/`pkg-config`, `gtk3-devel`/`libgtk-3-dev`, `libstdc++-devel`/`libstdc++-12-dev`, `mesa-libGLU`/`libglu1-mesa`) are declared in `.chezmoidata/packages.yaml` across Fedora and Ubuntu.
- R4. Web development prerequisites (Google Chrome/Chromium) are ensured via package authority/manifests.

**macOS Platform Toolchain (Android, Web, macOS Desktop, iOS)**

- R5. macOS desktop and iOS build prerequisites (`cocoapods`, Xcode CLI tools verification) are declared in `.chezmoidata/packages.yaml` under Homebrew capabilities.

**Android SDK & CLI Toolchain (Linux & macOS)**

- R6. OpenJDK (JDK 17+) is declared and installed via system package managers or runtime tooling on Linux and macOS.
- R7. Android SDK environment variables (`ANDROID_HOME=~/.local/share/android-sdk`, `ANDROID_SDK_ROOT`, `JAVA_HOME`, and `PATH` additions for `cmdline-tools/latest/bin` and `platform-tools`) are declared in shell and environment configurations.
- R8. An automated onchange script provisions Android `cmdline-tools` into `~/.local/share/android-sdk`, installs essential packages (`platform-tools`, `build-tools`, `platforms;android-36`), and accepts SDK licenses automatically.

**Verification & Health Checks**

- R9. `flutter doctor -v` and `flutter devices` run cleanly without unresolved toolchain or path errors for all enabled platforms.

### Key Decisions

- **Flutter installation location uses XDG data home (`~/.local/share/flutter/versions/<tag>`).** (session-settled: user-directed — chosen over `~/.flutter`: avoids polluting `$HOME` root while adhering to XDG Base Directory standards and repo conventions.) Governs R1, R2.
- **Flutter SDK delivery follows the `codex`/`codegraph` static release-lock and externals pattern.** (session-settled: user-directed — chosen over mise or brew: provides declarative static checksum verification, version isolation, and symlinking `bin/*` to `~/.local/bin` with automatic pruning.) Governs R1, R2.
- **Full cross-platform support across Linux and macOS.** (session-settled: user-directed — chosen over single-platform delivery: Linux supports Android, Web, Linux desktop; macOS supports Android, Web, macOS, iOS.) Governs R3, R4, R5, R6, R7, R8.
- **Android SDK and toolchain CLI automation.** (session-settled: user-directed — chosen over manual Android Studio GUI installation: automates `cmdline-tools`, `sdkmanager` packages, and license acceptance headlessly.) Governs R6, R7, R8.

### Scope Boundaries

- **Deferred / Non-goals:**
  - Pre-downloading large Android Virtual Device (AVD) system emulator images during chezmoi apply (AVD creation remains on-demand to save disk space and network bandwidth).
  - Apple Developer signing certificate automation or paid account setup (requires interactive Apple ID authorization).
  - Installing Flutter extensions in third-party unmanaged IDEs (VSCode/VSCodium extension management is handled via `vscodium.yaml` where applicable).

---

## Planning Contract

### Key Technical Decisions

- KTD1. **Flutter vendor resolution in `packages/release-lock`.** (session-settled: user-directed — chosen over GitHub API release assets: upstream `flutter/flutter` GitHub releases publish source code only, while binary SDK archives are published through Google Cloud Storage release manifests `releases_linux.json` and `releases_macos.json`). The resolver reads the stable channel release, resolves archive URLs and SHA256 checksums for `linux-amd64`, `linux-arm64` (emulated), `darwin-amd64`, and `darwin-arm64`, and records them in `.chezmoidata/releases.json`. Governs R1.
- KTD2. **Version symlink and prune lifecycle via `.chezmoiscripts/00-tools/run_onchange_after_flutter.sh.tmpl`.** (session-settled: user-directed — chosen over direct PATH manipulation: renders the locked tag into the script body so new releases trigger re-linking and pruning, points `~/.local/share/flutter/current` -> `versions/<tag>`, and symlinks all executable binaries in `current/bin/*` to `~/.local/bin/`). Governs R1, R2.
- KTD3. **Android SDK automated bootstrap script (`run_onchange_after_android-sdk.sh.tmpl`).** Installs `cmdline-tools` under `~/.local/share/android-sdk/cmdline-tools/latest`, uses `sdkmanager` to install `platform-tools`, `build-tools;35.0.0`, `platforms;android-36`, and automatically accepts licenses via `yes | sdkmanager --licenses`. Governs R7, R8.
- KTD4. **Environment declarations across Linux and macOS.** `dot_config/environment.d/60-development.conf` defines `ANDROID_HOME` and `ANDROID_SDK_ROOT` for Linux user systemd session, while `dot_config/zsh/dot_zprofile` exports them and includes `$ANDROID_HOME/cmdline-tools/latest/bin` and `$ANDROID_HOME/platform-tools` in `path`. Governs R7.
- KTD5. **Package authority and manifest registration in `.chezmoidata/packages.yaml`.** Linux packages include `gtk3-devel`, `cmake`, `ninja-build`, `mesa-libGLU`, and `java-latest-openjdk-devel`. macOS includes `cocoapods` (Homebrew formula) and `openjdk` (Homebrew formula) capabilities. Governs R3, R5, R6.

### Assumptions

- The host has network connectivity during initial apply to download the Flutter archive and Android command-line tools.
- Linux hosts (Fedora 40+) have GTK3 and OpenGL development libraries installable through standard Fedora repositories.
- macOS hosts have Homebrew installed and Xcode Command Line Tools (`xcode-select`) initialized.

### Risks

| Risk | Mitigation |
|---|---|
| Android `sdkmanager` requires a functional JDK at execution time | Ensure JDK package is installed before `run_onchange_after_android-sdk.sh.tmpl` executes (phase 00-tools ordering or explicit Java check) |
| Flutter SDK first-run post-install downloads (artifacts) | `flutter doctor` handles first-run cache warmup gracefully without root permissions |
| Large SDK download sizes slowing initial provisioning | Static release lock pins exact tarball/zip and skips download on subsequent applies if unchanged |

### Sources

- Flutter Official Manual Install: `https://docs.flutter.dev/install/manual`
- Flutter Linux Setup: `https://docs.flutter.dev/platform-integration/linux/setup`
- Flutter macOS Setup: `https://docs.flutter.dev/platform-integration/macos/setup`
- Flutter Android Setup: `https://docs.flutter.dev/platform-integration/android/setup`
- Flutter iOS Setup: `https://docs.flutter.dev/platform-integration/ios/setup`
- Flutter Web Setup: `https://docs.flutter.dev/platform-integration/web/setup`
- Release Lock Reference: `packages/release-lock/src/vendor-manifest.ts`

---

## Implementation Units

### U1. Register Flutter in `packages/release-lock`

**Goal:** Add `flutter` tool resolution via vendor manifests in `packages/release-lock`, resolving stable channel Linux and macOS archives and SHA256 checksums without downloading full binaries.

**Requirements:** R1.

**Dependencies:** None.

**Files:**
- `packages/release-lock/src/types.ts`
- `packages/release-lock/src/vendor-manifest.ts`
- `packages/release-lock/src/registry.ts`
- `packages/release-lock/test/vendor-manifest.test.ts`
- `packages/release-lock/test/registry.test.ts`

**Approach:**
1. Update `VendorName` in `types.ts` to include `"flutter"`.
2. Implement `resolveFlutter` in `vendor-manifest.ts` querying `releases_linux.json` and `releases_macos.json` for current stable releases, populating `artifacts` for `linux-amd64`, `linux-arm64` (emulated), `darwin-amd64`, and `darwin-arm64`.
3. Add `flutter` entry to `REGISTRY` in `registry.ts` with `kind: "vendorManifest"` and `source: "flutter"`.
4. Add unit test suites in `vendor-manifest.test.ts` and `registry.test.ts` validating manifest resolution and routing without network I/O.

**Test scenarios:**
- `pnpm --filter release-lock test` passes cleanly.
- Unit tests verify `flutter` returns correct archive URLs and digests for all target architectures.

---

### U2. Declare Flutter in `.chezmoiexternals/dev-tools.toml` and `.chezmoiscripts/00-tools/`

**Goal:** Extract Flutter SDK to `~/.local/share/flutter/versions/<tag>` and manage symlinking to `~/.local/bin/` with older version pruning.

**Requirements:** R1, R2.

**Dependencies:** U1.

**Files:**
- `.chezmoiexternals/dev-tools.toml`
- `.chezmoiscripts/00-tools/run_onchange_after_flutter.sh.tmpl`

**Approach:**
1. In `.chezmoiexternals/dev-tools.toml`, add `[flutter]` external archive targeting `~/.local/share/flutter/versions/<tag>` with `stripComponents = 1`.
2. Create `.chezmoiscripts/00-tools/run_onchange_after_flutter.sh.tmpl` with onchange tag rendering, linking `~/.local/share/flutter/current` -> `dest`, symlinking `current/bin/*` to `~/.local/bin/`, and pruning non-current directories under `versions/`.

**Test scenarios:**
- `chezmoi execute-template < .chezmoiscripts/00-tools/run_onchange_after_flutter.sh.tmpl` renders valid shell script.
- Script correctly handles symlinking executable binaries and skips non-executables.

---

### U3. Configure Android SDK environment in `environment.d` and `zsh`

**Goal:** Declare Android SDK environment variables (`ANDROID_HOME`, `ANDROID_SDK_ROOT`) and path additions for `cmdline-tools` and `platform-tools`.

**Requirements:** R7.

**Dependencies:** None.

**Files:**
- `dot_config/environment.d/60-development.conf`
- `dot_config/zsh/dot_zprofile`

**Approach:**
1. In `dot_config/environment.d/60-development.conf`, add `ANDROID_HOME=${HOME}/.local/share/android-sdk` and `ANDROID_SDK_ROOT=${HOME}/.local/share/android-sdk`.
2. In `dot_config/zsh/dot_zprofile`, export `ANDROID_HOME` and `ANDROID_SDK_ROOT`, and prepend `$HOME/.local/share/android-sdk/cmdline-tools/latest/bin` and `$HOME/.local/share/android-sdk/platform-tools` to `path`.

**Test scenarios:**
- Shell launch in zsh includes `$ANDROID_HOME` and both directories in `PATH`.
- Systemd user environment configuration is valid key-value pairs.

---

### U4. Add Android SDK CLI automated provisioning script

**Goal:** Automate downloading Android `cmdline-tools`, installing essential SDK components via `sdkmanager`, and accepting licenses.

**Requirements:** R8.

**Dependencies:** U3.

**Files:**
- `.chezmoiscripts/00-tools/run_onchange_after_android-sdk.sh.tmpl`

**Approach:**
1. Create `.chezmoiscripts/00-tools/run_onchange_after_android-sdk.sh.tmpl`.
2. Verify if `cmdline-tools/latest/bin/sdkmanager` exists; if not, download and unpack Google's commandline-tools zip to `~/.local/share/android-sdk/cmdline-tools/latest`.
3. Execute `sdkmanager --sdk_root="$ANDROID_HOME"` to install `platform-tools`, `build-tools;35.0.0`, `platforms;android-36`, `cmdline-tools;latest`.
4. Run `yes | sdkmanager --licenses` to accept all SDK licenses.

**Test scenarios:**
- Script runs idempotently without re-downloading if tools already exist.
- Script handles license acceptance non-interactively.

---

### U5. Declare platform build packages in `.chezmoidata/packages.yaml`

**Goal:** Declare Linux and macOS development packages required for Linux desktop, macOS desktop, iOS, Web, and Android builds.

**Requirements:** R3, R4, R5, R6.

**Dependencies:** None.

**Files:**
- `.chezmoidata/packages.yaml`

**Approach:**
1. In `.chezmoidata/packages.yaml` under `packages.linux.fedora.packages`, ensure `gtk3-devel`, `cmake`, `ninja-build`, `mesa-libGLU`, and `java-latest-openjdk-devel` are declared.
2. Under `authority.capabilities`, add capabilities for `cocoapods` (Homebrew formula) and `openjdk` (Homebrew formula) for macOS hosts.
3. Validate schema and origins with `.ci/test-packages-manifest.sh` and `.ci/test-package-ownership.sh`.

**Test scenarios:**
- `.ci/test-packages-manifest.sh` exits 0.
- `.ci/test-package-ownership.sh` exits 0.

---

## Verification Contract

| Gate | Command / check | Done signal |
|---|---|---|
| Release lock unit tests | `pnpm --filter release-lock test` | exits 0 |
| Packages manifest validation | `.ci/test-packages-manifest.sh` | exits 0 |
| Package ownership consistency | `.ci/test-package-ownership.sh` | exits 0 |
| Template rendering checks | `chezmoi execute-template < .chezmoiscripts/00-tools/run_onchange_after_flutter.sh.tmpl` | renders valid bash |
| Android SDK script render | `chezmoi execute-template < .chezmoiscripts/00-tools/run_onchange_after_android-sdk.sh.tmpl` | renders valid bash |
| Diff hygiene | `git diff --check`, `git status` | clean, scoped to intended files |

---

## Definition of Done

- All 5 implementation units (U1–U5) are implemented and pass unit/render tests.
- Flutter SDK is extracted to `~/.local/share/flutter/versions/<tag>` and `flutter`/`dart` are symlinked to `~/.local/bin/`.
- Android SDK CLI environment is provisioned at `~/.local/share/android-sdk` with `cmdline-tools`, `platform-tools`, and licenses accepted.
- Linux desktop build packages (`gtk3-devel`, `cmake`, `ninja-build`, `mesa-libGLU`, `openjdk`) and macOS capabilities (`cocoapods`, `openjdk`) are declared in `.chezmoidata/packages.yaml`.
- All Verification Contract test scripts pass cleanly.
