---
title: KDE Plasma Google OAuth KAccounts User Provider Override and Dolphin 403 Resolution
date: 2026-09-01
category: integration-issues
module: kde
problem_type: integration_issue
component: authentication
symptoms:
  - "Dolphin displays '에 대한 접근이 거부되었습니다' (Access Denied / 403) when accessing Google Drive (gdrive:/)"
  - "KDE System Settings Online Accounts uses upstream shared Google OAuth Client ID instead of user custom OAuth provider"
  - "Google OAuth tokens missing https://www.googleapis.com/auth/drive scope"
root_cause: config_error
resolution_type: config_change
severity: medium
related_components:
  - infrastructure
  - tooling
tags:
  - kde
  - plasma
  - google-drive
  - kio-gdrive
  - kaccounts
  - libaccounts-glib
  - oauth
  - 1password
---

# KDE Plasma Google OAuth KAccounts User Provider Override and Dolphin 403 Resolution

## Problem

When connecting a personal Google account to KDE Plasma on Fedora KDE Spin, Dolphin's Google Drive integration (`kio-gdrive`, navigating to `gdrive:/<account>`) failed with a red banner error: `"에 대한 접근이 거부되었습니다"` (Access Denied / 403 Forbidden).

Furthermore, attempting to override the system Google OAuth provider with a private Google Cloud OAuth 2.0 app initially failed because KDE's `libaccounts-glib` engine silently ignored user-level provider definitions placed under subdirectories (`~/.local/share/accounts/providers/kde/google.provider`).

## Symptoms

- Dolphin navigation to `gdrive:/` listed the added Google account folder, but clicking it immediately showed `"에 대한 접근이 거부되었습니다. 불러오기 취소됨"` (Access denied. Loading cancelled).
- In KDE System Settings -> Online Accounts (`kcm_kaccounts`), the Google account displayed only `Drive` and `YouTube` services.
- Inspecting `~/.config/libaccounts-glib/accounts.db` showed that the account was created with upstream KDE shared credentials (`ClientId: 317066460457-pkpkedrvt2ldq6g2hj1egfka2n7vpuoo.apps.googleusercontent.com`) and lacked the `https://www.googleapis.com/auth/drive` OAuth scope.

## What Didn't Work

- **Placing the user override in `~/.local/share/accounts/providers/kde/google.provider`**: System provider files reside in `/usr/share/accounts/providers/kde/google.provider` (using the desktop-specific directory). However, `libaccounts-glib`'s `_ag_find_libaccounts_file` searches `$XDG_DATA_HOME/accounts/providers/<name>.provider` without appending the desktop subdirectory (`kde/`). Consequently, `~/.local/share/accounts/providers/kde/google.provider` was skipped, and libaccounts fell back to `/usr/share/accounts/providers/kde/google.provider`.
- **Assuming KAccounts manages KDE PIM (Kontact/KOrganizer) calendar and contacts**: In KDE Plasma 6, `kaccounts-providers` only supplies `google-drive.service` and `google-youtube.service`. Calendar, Tasks, and Contacts are handled independently by Akonadi's `akonadi_google_resource` and `libkgapi` via Google Groupware.

## Solution

### 1. Correct User-Level Provider Override Path

Place the custom `google.provider` directly in `~/.local/share/accounts/providers/google.provider` (source: `dot_local/share/accounts/providers/google.provider.tmpl`).

In `dot_local/share/accounts/providers/google.provider.tmpl`:
```xml
<?xml version="1.0" encoding="UTF-8" ?>
<provider id="google">
  <name>Google</name>
  <description>Sync calendars, contacts, and tasks, and upload videos to YouTube in supported apps</description>
  <icon>im-google</icon>
  <translations>kaccounts-providers</translations>
  <domains>.*google\.com</domains>

  <template>
    <group name="auth">
      <setting name="method">oauth2</setting>
      <setting name="mechanism">web_server</setting>
      <group name="oauth2">
        <group name="web_server">
          <setting name="Host">accounts.google.com</setting>
          <setting name="AuthPath">o/oauth2/auth?access_type=offline&amp;approval_prompt=force</setting>
          <setting name="TokenPath">o/oauth2/token</setting>
          <setting name="RedirectUri">http://localhost/oauth2callback</setting>
          <setting name="ResponseType">code</setting>
          <setting name="Scope" type="as">[
              'https://www.googleapis.com/auth/userinfo.email',
              'https://www.googleapis.com/auth/userinfo.profile',
              'https://www.googleapis.com/auth/calendar',
              'https://www.googleapis.com/auth/tasks',
              'https://www.google.com/m8/feeds/',
              'https://www.googleapis.com/auth/drive',
              'https://www.googleapis.com/auth/youtube.upload'
          ]</setting>
          <setting name="AllowedSchemes" type="as">['https']</setting>
          <setting name="ClientId">{{ onepasswordRead (default "op://Private/Google-KDE-OAuth/client_id" (dig "googleOAuth" "clientIdRef" "" .kde)) }}</setting>
          <setting name="ClientSecret">{{ onepasswordRead (default "op://Private/Google-KDE-OAuth/client_secret" (dig "googleOAuth" "clientSecretRef" "" .kde)) }}</setting>
          <setting name="ForceClientAuthViaRequestBody" type="b">true</setting>
        </group>
      </group>
    </group>
  </template>
</provider>
```

### 2. 1Password Secret Storage

Store the private Google Cloud OAuth 2.0 Web Application credentials in 1Password under vault `Private` and item `Google-KDE-OAuth`:
- `client_id`: `<project_id>.apps.googleusercontent.com`
- `client_secret`: `<client_secret>` (password/concealed type)

### 3. Re-Authenticating Account in KDE

1. In System Settings -> Online Accounts (`kcm_kaccounts`), delete any previously created Google account.
2. Add Google account again. `libaccounts-glib` reads `~/.local/share/accounts/providers/google.provider`, launches the OAuth flow with the private Client ID and `drive` scope, and Dolphin `gdrive:/` immediately connects.

## Why This Works

1. `libaccounts-glib`'s search logic in `_ag_find_libaccounts_file`:
   - Checks `$AG_PROVIDERS` environment variable.
   - Checks `$XDG_DATA_HOME/accounts/providers/<name>.provider` (`g_get_user_data_dir()` + `accounts/providers/<name>.provider`).
   - Checks `$XDG_DATA_DIRS/accounts/providers/<desktop>/<name>.provider` (`/usr/share/accounts/providers/kde/<name>.provider`).
   Deploying to `~/.local/share/accounts/providers/google.provider` takes top priority and overrides `/usr/share/accounts/providers/kde/google.provider`.
2. Including `'https://www.googleapis.com/auth/drive'` in the provider `<setting name="Scope">` ensures Google issues an OAuth refresh/access token authorized for Google Drive API operations, resolving the 403 Forbidden error in `kio-gdrive`.

## Prevention

- **Always verify libaccounts lookup paths with `strace` or python `gi.repository.Accounts`**:
  ```bash
  strace -e trace=openat,access python3 -c "
  import gi
  gi.require_version('Accounts', '1.0')
  from gi.repository import Accounts
  Accounts.Manager().get_provider('google')
  " 2>&1 | grep -E 'accounts/providers'
  ```
- **Inspect `accounts.db` to verify resolved credentials**:
  ```bash
  sqlite3 ~/.config/libaccounts-glib/accounts.db "SELECT * FROM Settings WHERE key LIKE '%ClientId%' OR key LIKE '%Scope%';"
  ```
- **Akonadi/PIM separation**: Keep in mind that KDE PIM (KOrganizer, Kontact) uses `akonadi_google_resource` and `libkgapi`, which operates separately from `kaccounts-providers`.
