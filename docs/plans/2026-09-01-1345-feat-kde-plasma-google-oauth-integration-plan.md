---
title: "Feature: KDE Plasma Dedicated Google OAuth Account Integration Plan"
created_at: 2026-09-01
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-brainstorm
execution: code
---

## Goal Capsule

- **Objective**: Enable full Google account integration (Google Drive, Calendar, Tasks, Contacts) in KDE Plasma using a dedicated private Google Cloud OAuth 2.0 application managed securely via 1Password and Chezmoi.
- **Product Authority**: Single-user workstation configuration in `github.com/hyperlapse122/dotfiles` with 1Password secret resolution and Fedora KDE Spin desktop environment.
- **Means**: Provision `~/.local/share/accounts/providers/kde/google.provider` via a Chezmoi template reading private OAuth credentials from 1Password (`op://Private/Google-KDE-OAuth/...`), and declare required KDE KAccounts/KIO/Akonadi packages. (KTD1, KTD2)
- **Execution Profile**: `code`
- **Open Blockers**: None

---

## Product Contract

### Summary

This feature integrates a personal Google account into KDE Plasma desktop services (Dolphin `gdrive:/`, Digital Clock calendar events, Akonadi tasks and contacts) using a dedicated private Google OAuth 2.0 client. Private OAuth credentials (Client ID and Secret) are managed in 1Password and injected into `~/.local/share/accounts/providers/kde/google.provider` via a Chezmoi template, bypassing Google's third-party OAuth quota restrictions and unverified app blocks.

### Problem Frame

KDE Plasma's upstream `kaccounts-providers` package ships with a shared public Google OAuth Client ID. Over time, Google restricts or disables access for shared open-source OAuth clients, triggering "This app is blocked" or "Unverified app" warnings and breaking desktop calendar, contact, and Google Drive syncing.

Using a personal Google Cloud project with a private OAuth 2.0 client resolves authentication reliability. Integrating credential management with 1Password (`op://`) provides a reproducible, secure, and declarative dotfiles workflow without checking secrets into git.

### Key Decisions

- **Private Google Cloud OAuth 2.0 app credentials** (session-settled: user-directed — chosen over public/shared KDE credentials: prevents Google unverified app blocks and shared quota exhaustion). Governs R1, R4.
- **Automated credential injection via Chezmoi template with 1Password op://** (session-settled: user-directed — chosen over manual local file creation or static unencrypted config: keeps secrets out of git while ensuring automated deployment). Governs R2, R3.
- **Full service integration scope (Drive + Calendar/Tasks + Contacts)** (session-settled: user-directed — chosen over Drive-only or Calendar-only: provides complete desktop environment integration). Governs R1, R5, R6, R7.

### Actors

- **A1: Desktop Operator / User**: Manages GCP project credentials in 1Password and logs in via KDE System Settings Online Accounts.
- **A2: Chezmoi Provisioner**: Renders `dot_local/share/accounts/providers/kde/google.provider.tmpl` with live secrets resolved from 1Password.
- **A3: KDE KAccounts & Signon-UI**: Reads the user-level `google.provider` override, drives OAuth 2.0 authorization code flow via loopback redirect, and manages tokens in KWallet.
- **A4: Google Cloud Platform**: Authenticates OAuth requests and serves Google Drive, Calendar, Tasks, and People (Contacts) APIs.

### Requirements

**OAuth Provider & Credential Management**
- R1. Provide a user-level KDE accounts provider template at `dot_local/share/accounts/providers/kde/google.provider.tmpl` that overrides `/usr/share/accounts/providers/kde/google.provider` with dedicated Client ID and Client Secret values.
- R2. Resolve the OAuth Client ID and Client Secret in `google.provider.tmpl` from 1Password via Chezmoi's `onepasswordRead` / `op://` reference resolver.
- R3. Support configuring the 1Password item reference path in `.chezmoidata/kde.yaml` (defaulting to standard path `op://Private/Google-KDE-OAuth/client_id` and `op://Private/Google-KDE-OAuth/client_secret`).
- R4. Configure the OAuth provider XML with redirect URI `http://localhost/oauth2callback` and scopes covering `drive`, `calendar`, `tasks`, `https://www.google.com/m8/feeds/`, `userinfo.email`, and `userinfo.profile`.

**Package Provisioning & Desktop Integration**
- R5. Ensure package dependencies (`kaccounts-integration-qt6`, `kaccounts-providers`, `kio-gdrive`, `kdepim-runtime`, `signon-kwallet-extension`) are declared in `.chezmoiscripts/30-components/run_onchange_before_70-apps.sh.tmpl` or equivalent package lists for Fedora.
- R6. Enable Dolphin file manager access to Google Drive files and folders via `kio-gdrive` (`gdrive:/`).
- R7. Enable Digital Clock popup and Akonadi calendar/task synchronization for Google Calendar and Google Tasks events.

### Key Flows

- F1. **Dotfiles Apply & Provider Injection**
  - **Trigger:** User runs `chezmoi apply`.
  - **Actors:** A2 (Chezmoi), 1Password CLI (`op`).
  - **Steps:** Chezmoi renders `dot_local/share/accounts/providers/kde/google.provider.tmpl`, resolves `client_id` and `client_secret` from 1Password, and writes `~/.local/share/accounts/providers/kde/google.provider`.
  - **Outcome:** KDE Plasma detects custom `google.provider` with user-specific OAuth credentials.
  - **Covered by:** R1, R2, R3, R4.

- F2. **KDE Account Sign-in & Service Activation**
  - **Trigger:** User opens KDE System Settings -> Online Accounts -> Add Google Account.
  - **Actors:** A1 (User), A3 (KDE KAccounts/Signon-UI), A4 (GCP).
  - **Steps:** Signon-ui opens browser with custom OAuth client ID; user approves consent; browser redirects to `http://localhost/oauth2callback`; Signon-ui exchanges authorization code for refresh token and stores in KWallet; KIO GDrive and Akonadi start syncing.
  - **Outcome:** Google Drive appears in Dolphin; Google Calendar events appear in KDE Digital Clock.
  - **Covered by:** R1, R5, R6, R7.

### Acceptance Examples

- AE1. **Provider template renders with 1Password credentials**
  - **Covers:** R1, R2, R3, R4
  - **Given:** 1Password contains `client_id` and `client_secret` under item `Google-KDE-OAuth`.
  - **When:** `chezmoi apply` renders `~/.local/share/accounts/providers/kde/google.provider`.
  - **Then:** The rendered file contains the custom `ClientId` and `ClientSecret` values and redirect URI `http://localhost/oauth2callback`, with no plaintext secrets committed to git.

- AE2. **Google Drive browsing in Dolphin**
  - **Covers:** R5, R6
  - **Given:** User completes Google sign-in in KDE System Settings.
  - **When:** User navigates to `gdrive:/` in Dolphin.
  - **Then:** Google Drive directories and files are listed and readable.

- AE3. **Calendar and Task sync in Digital Clock / Akonadi**
  - **Covers:** R5, R7
  - **Given:** Google account is authenticated in KAccounts.
  - **When:** Akonadi calendar resource synchronizes.
  - **Then:** Digital Clock popup displays Google Calendar events.

### Scope Boundaries

- **In-Scope:**
  - `dot_local/share/accounts/providers/kde/google.provider.tmpl` Chezmoi template with 1Password resolution.
  - `.chezmoidata/kde.yaml` configurable 1Password reference path fields.
  - Package declarations for `kaccounts-integration-qt6`, `kaccounts-providers`, `kio-gdrive`, `kdepim-runtime`, `signon-kwallet-extension`.
  - Verification of Google Drive, Calendar, Tasks, and Contacts integration in KDE Plasma 6.
- **Out-of-Scope:**
  - Multi-account rotation or automated token switching across multiple Google accounts.
  - Automated public OAuth app verification submission to Google.

### Outstanding Questions

- None. All scope boundaries and design decisions were settled during dialogue.

---

## Planning Contract

### Product Contract Preservation

Product Contract unchanged. Requirements R1–R7, Actors A1–A4, Flows F1–F2, Acceptance Examples AE1–AE3, and Key Decisions are preserved in full.

### Key Technical Decisions

- **KTD1. User-level XDG override for KDE accounts provider XML**
  - **Decision:** Deploy custom Google provider definition to `~/.local/share/accounts/providers/kde/google.provider` rather than mutating `/usr/share/accounts/providers/kde/google.provider`. (session-settled: user-directed — chosen over system file mutation: isolates configuration to user seat and preserves package manager state).
  - **Governs:** R1, R4.

- **KTD2. Dynamic 1Password reference path with fallback in `.chezmoidata/kde.yaml`**
  - **Decision:** Resolve 1Password reference strings through `.chezmoidata/kde.yaml` (defaulting to `op://Private/Google-KDE-OAuth/client_id` and `op://Private/Google-KDE-OAuth/client_secret`) with fallback support. (session-settled: user-directed — chosen over hardcoded string: enables flexible vault configuration across environments).
  - **Governs:** R2, R3.

- **KTD3. Loopback redirect URI `http://localhost/oauth2callback` and Web Client OAuth type**
  - **Decision:** Pinned to `http://localhost/oauth2callback` in `google.provider.tmpl` matching KDE signon-ui's built-in OAuth2 web server flow, with scopes for Google Drive (`https://www.googleapis.com/auth/drive`), Calendar (`https://www.googleapis.com/auth/calendar`), Tasks (`https://www.googleapis.com/auth/tasks`), Contacts (`https://www.google.com/m8/feeds/`), and profile/email.
  - **Governs:** R4.

### High-Level Technical Design

```mermaid
flowchart TB
  subgraph Deploy_Phase ["1. Dotfiles Provisioning"]
    Chezmoi["chezmoi apply"] -->|Reads op://| Vault["1Password Vault\n(Private / Google-KDE-OAuth)"]
    Chezmoi -->|Renders| ProviderFile["~/.local/share/accounts/providers/kde/google.provider"]
    AppInstall[".chezmoiscripts/30-components/70-apps"] -->|Installs| Pkgs["kaccounts-integration-qt6\nkaccounts-providers\nkio-gdrive\nkdepim-runtime\nsignon-kwallet-extension"]
  end

  subgraph Runtime_Phase ["2. KDE Plasma Integration"]
    User["Desktop User"] -->|Adds Google Account| KCM["KDE System Settings\n(Online Accounts)"]
    KCM -->|Reads Provider| ProviderFile
    KCM -->|OAuth2 Loopback Sign-in| GoogleAuth["Google Accounts Login"]
    GoogleAuth -->|OAuth Code Callback| SignOn["signon-ui / KWallet"]
    SignOn -->|Auth Tokens| KIO["Dolphin (gdrive:/)"]
    SignOn -->|Calendar Tokens| Akonadi["Akonadi / Digital Clock"]
  end
```

---

## Implementation Units

### U1. Declare Google OAuth reference paths in `.chezmoidata/kde.yaml`

- **Goal:** Add configuration fields in `.chezmoidata/kde.yaml` to store the 1Password reference paths for the Google OAuth Client ID and Client Secret.
- **Requirements:** R3 (Governed by KTD2)
- **Dependencies:** None
- **Files:**
  - `.chezmoidata/kde.yaml`
- **Approach:**
  1. Add a `googleOAuth` block under `kde:` in `.chezmoidata/kde.yaml`.
  2. Declare `clientIdRef: "op://Private/Google-KDE-OAuth/client_id"` and `clientSecretRef: "op://Private/Google-KDE-OAuth/client_secret"`.
- **Patterns to follow:**
  - Structure in `.chezmoidata/kde.yaml` alongside `kde.calendar` and `kde.settings`.
- **Test scenarios:**
  - Scenario 1 (Happy path): `chezmoi execute-template` successfully reads `.kde.googleOAuth.clientIdRef` and `.kde.googleOAuth.clientSecretRef`.
- **Verification:**
  - Verify `.chezmoidata/kde.yaml` syntax is valid YAML and matches repository schema conventions.

---

### U2. Create Chezmoi template for KDE Google OAuth provider

- **Goal:** Author `dot_local/share/accounts/providers/kde/google.provider.tmpl` which renders the custom provider XML with 1Password credentials.
- **Requirements:** R1, R2, R3, R4 (Governed by KTD1, KTD2, KTD3, Covers AE1)
- **Dependencies:** U1
- **Files:**
  - `dot_local/share/accounts/providers/kde/google.provider.tmpl`
- **Approach:**
  1. Mirror the provider structure of `/usr/share/accounts/providers/kde/google.provider`.
  2. Retrieve `clientIdRef` and `clientSecretRef` from `.kde.googleOAuth` (defaulting to `op://Private/Google-KDE-OAuth/...`).
  3. Resolve secrets using `onepasswordRead` helper.
  4. Ensure `RedirectUri` is set to `http://localhost/oauth2callback`.
  5. Include all required scopes: `https://www.googleapis.com/auth/userinfo.email`, `https://www.googleapis.com/auth/userinfo.profile`, `https://www.googleapis.com/auth/calendar`, `https://www.googleapis.com/auth/tasks`, `https://www.google.com/m8/feeds/`, `https://www.googleapis.com/auth/drive`, `https://www.googleapis.com/auth/youtube.upload`.
- **Patterns to follow:**
  - Template structure in `dot_local/share/` and 1Password secret resolution in `private_executable_import-wifi-1password.tmpl`.
- **Test scenarios:**
  - Scenario 1 (Happy path - AE1): Render template using live 1Password resolution or scratch `op` stub; verify generated XML has valid XML syntax, contains the injected client ID/secret, and contains `http://localhost/oauth2callback`.
  - Scenario 2 (Security/Privacy): Verify template file does not contain hardcoded plaintext credentials and complies with repository secrets policy.
- **Verification:**
  - Run `chezmoi execute-template < dot_local/share/accounts/providers/kde/google.provider.tmpl` and validate XML structure.

---

### U3. Update package provisioning for KDE online accounts dependencies

- **Goal:** Ensure all required packages for KDE Online Accounts, Google Drive KIO worker, Akonadi PIM runtime, and KWallet Signon integration are present in package manifests.
- **Requirements:** R5, R6, R7 (Covers AE2, AE3)
- **Dependencies:** None
- **Files:**
  - `.chezmoiscripts/30-components/run_onchange_before_70-apps.sh.tmpl`
- **Approach:**
  1. Review `app_packages` array in `.chezmoiscripts/30-components/run_onchange_before_70-apps.sh.tmpl`.
  2. Add `kaccounts-integration-qt6`, `kaccounts-providers`, `kio-gdrive`, `kdepim-runtime`, `signon-kwallet-extension` to `app_packages`.
  3. Ensure idempotency (only uninstalled packages are passed to `dnf install`).
- **Patterns to follow:**
  - Package installation loop in `run_onchange_before_70-apps.sh.tmpl`.
- **Test scenarios:**
  - Scenario 1 (Happy path): On Fedora host, `install_app_packages` correctly checks `rpm -q` and includes missing KDE online accounts packages.
- **Verification:**
  - Verify `run_onchange_before_70-apps.sh.tmpl` renders cleanly and passes skip/guard checks.

---

## Verification Contract

### Test Commands and Quality Gates

- **Template Rendering & Secret Gate:**
  ```bash
  chezmoi execute-template < dot_local/share/accounts/providers/kde/google.provider.tmpl
  ```
  - **Expected Outcome:** Template renders valid XML containing the live ClientId and ClientSecret, `http://localhost/oauth2callback`, and required scopes.

- **Manifest Validation & Shell Syntax:**
  ```bash
  bash .ci/test-command-manifest.sh
  bash .ci/check-skip-declarations.sh
  git diff --check
  ```
  - **Expected Outcome:** Zero syntax errors or trailing whitespace issues.

- **KDE Desktop Integration Verification:**
  1. Verify `~/.local/share/accounts/providers/kde/google.provider` is deployed.
  2. Open `systemsettings kcm_kaccounts` -> Add Google Account -> Complete OAuth login.
  3. Verify Dolphin (`gdrive:/`) and Digital Clock calendar sync.

---

## Definition of Done

- [x] `.chezmoidata/kde.yaml` declares `googleOAuth` configuration references.
- [x] `dot_local/share/accounts/providers/kde/google.provider.tmpl` is created with 1Password secret resolution and correct OAuth redirect/scope parameters.
- [x] `.chezmoiscripts/30-components/run_onchange_before_70-apps.sh.tmpl` declares all required KDE accounts and KIO/Akonadi packages.
- [x] `~/.local/share/accounts/providers/kde/google.provider` is deployed via `chezmoi apply`.
- [x] Template execution and CI checks pass cleanly.
- [x] Git diff is clean and scoped strictly to the planned changes.
