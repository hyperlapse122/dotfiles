#!/usr/bin/env pwsh
#Requires -Version 5.1
<#
.SYNOPSIS
    install-prerequisites.ps1 — chezmoi `read-source-state.pre` hook (Windows).

.DESCRIPTION
    Windows counterpart to .install-prerequisites.sh. chezmoi runs this hook
    *before* it reads the source state, so the tooling secret templates and
    provisioning depend on is installed first:

      * 1Password + 1Password CLI (`op`) — secret templates call `onepasswordRead`,
        which requires an authenticated `op`.
      * mise — the runtime / CLI version manager the rest of this config relies on.

    Everything installs via winget (the "App Installer" package manager). chezmoi
    maps the .ps1 extension to the PowerShell interpreter ONLY for the `script`
    hook form (`pwsh`/`powershell -NoLogo -File <path>`); the `command` form execs
    the path directly, which Windows cannot do for a .ps1. So .chezmoi.toml.tmpl
    MUST wire this as `script = ...`, and — like its POSIX sibling — this file MUST
    NOT be a `.tmpl` (chezmoi runs hook scripts verbatim, never as templates).

    POSIX counterpart: .install-prerequisites.sh (Linux/macOS). Keep the two in
    sync. The Linux-only container / distrobox detection has no Windows analogue
    and is intentionally omitted; the non-interactive fail-fast below still keeps
    CI (e.g. windows-latest with OP_SERVICE_ACCOUNT_TOKEN) from hanging.
#>

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Mirror the shell script's `>&2`: emit guidance / progress on stderr without
# raising a terminating error (Write-Error would abort under -ErrorAction Stop).
function Write-Stderr {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string] $Message)
    [Console]::Error.WriteLine($Message)
}

# Run a native command, swallow its output, and return its exit code WITHOUT
# letting a non-zero exit raise a terminating error: PowerShell 7.4+ turns native
# failures into throws under $ErrorActionPreference='Stop', and several checks
# below (`op whoami`, `winget list`) treat a non-zero exit as expected signal.
function Invoke-NativeExitCode {
    param(
        [Parameter(Mandatory = $true)][string] $FilePath,
        [string[]] $Arguments = @()
    )
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $FilePath @Arguments *> $null
        return $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previous
    }
}

# winget persists PATH to the registry but not to this already-running process,
# so a freshly installed `op` / `mise` stays invisible until we re-read PATH from
# the Machine + User scopes. Called after the installs, before the auth checks.
function Update-SessionPath {
    # Keep this process's PATH and append the Machine + User scopes, so newly
    # installed tools become findable without dropping anything already set.
    $parts = @($env:Path)
    foreach ($scope in 'Machine', 'User') {
        $parts += [Environment]::GetEnvironmentVariable('Path', $scope)
    }
    $env:Path = ($parts | Where-Object { $_ }) -join ';'
}

# `op` can resolve secrets. `op whoami` succeeds for BOTH a desktop-app
# integration and a service-account token (OP_SERVICE_ACCOUNT_TOKEN) — the latter
# is how CI authenticates. `op user get --me` is the legacy fallback: it works for
# a signed-in human account but NOT a service account.
function Test-OpReady {
    if (-not (Get-Command op -ErrorAction SilentlyContinue)) { return $false }
    if ((Invoke-NativeExitCode -FilePath 'op' -Arguments @('whoami')) -eq 0) { return $true }
    return ((Invoke-NativeExitCode -FilePath 'op' -Arguments @('user', 'get', '--me')) -eq 0)
}

# Human-facing instructions for enabling the 1Password CLI. Printed once before
# waiting and again on timeout. Mirrors the flow in README.md, with a headless
# service-account escape hatch.
function Show-OpAuthGuidance {
    Write-Stderr 'install-prerequisites.ps1: 1Password CLI is not authenticated yet.'
    Write-Stderr 'Let chezmoi resolve secrets by enabling the 1Password CLI:'
    Write-Stderr '  1. Open the 1Password desktop app and sign in.'
    Write-Stderr '  2. Enable Settings -> Developer -> Integrate with 1Password CLI.'
    Write-Stderr '  (Headless host? Export a service-account token instead and re-run:'
    Write-Stderr "     `$env:OP_SERVICE_ACCOUNT_TOKEN = '...'   # op service account create --help)"
}

# Poll Test-OpReady until it succeeds or a bounded deadline elapses. Interval and
# max-wait are env-overridable so a harness can drive it fast with a stubbed `op`.
function Wait-ForOpAuth {
    $interval = if ($env:OP_AUTH_POLL_INTERVAL_SECS) { [int] $env:OP_AUTH_POLL_INTERVAL_SECS } else { 5 }
    $maxWait  = if ($env:OP_AUTH_MAX_WAIT_SECS) { [int] $env:OP_AUTH_MAX_WAIT_SECS } else { 900 }
    $waited = 0
    while (-not (Test-OpReady)) {
        if ($waited -ge $maxWait) {
            Write-Stderr "install-prerequisites.ps1: timed out after ${maxWait}s waiting for 1Password CLI auth."
            Show-OpAuthGuidance
            return $false
        }
        Start-Sleep -Seconds $interval
        $waited += $interval
        if (($waited % 30) -eq 0) {
            Write-Stderr "  .. still waiting for 1Password CLI sign-in (${waited}s elapsed)"
        }
    }
    return $true
}

# Return $true once `op` can resolve secrets. Already authed -> return at once.
# Otherwise guide the user; fail fast (like a CI run) when stdin is redirected so
# a headless invocation never hangs; else wait interactively.
function Confirm-OpAuthenticated {
    if (Test-OpReady) { return $true }
    Show-OpAuthGuidance
    # A redirected/piped stdin (CI, `chezmoi ... < file`) is the Windows analogue
    # of the shell's `! -t 0`; never block it waiting for a sign-in that a
    # non-interactive session cannot complete.
    if ([Console]::IsInputRedirected) {
        Write-Stderr 'install-prerequisites.ps1: non-interactive shell; cannot wait for sign-in.'
        return $false
    }
    if (Wait-ForOpAuth) {
        Write-Stderr 'install-prerequisites.ps1: 1Password CLI authenticated; continuing.'
        return $true
    }
    return $false
}

# config-secrets key: mirrors ensure_config_secrets_key in
# .install-prerequisites.sh (keep the two in sync). The chezmoi config template
# stores its prompted secrets AES-encrypted with a key that lives ONLY in the
# user credential store — Windows Credential Manager here, which works even in
# headless sessions — under service=chezmoi-config-secrets / user=<username>.
# No Windows-targeted template consumes it today (both encrypted secrets are
# Linux-only), but the key infrastructure stays in lockstep with the POSIX
# hook. Never fails the hook: a credential-store error only means the config
# template treats its secrets as absent.
function Confirm-ConfigSecretsKey {
    if (-not (Get-Command chezmoi -ErrorAction SilentlyContinue)) { return }
    $service = 'chezmoi-config-secrets'
    $user = $env:UserName
    if (-not $user) { return }
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $existing = & chezmoi secret keyring get --service $service --user $user 2> $null
        if ($LASTEXITCODE -eq 0 -and $existing) { return }
        $bytes = [byte[]]::new(32)
        [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
        $key = [Convert]::ToBase64String($bytes)
        & chezmoi secret keyring set --service $service --user $user --value $key 2> $null
        if ($LASTEXITCODE -ne 0) {
            Write-Stderr 'install-prerequisites.ps1: credential store unreachable; config-template secrets cannot be stored this run.'
        }
    } finally {
        $ErrorActionPreference = $previous
    }
}

# Host-fact cache: mirrors write_facts_cache in .install-prerequisites.sh (keep
# the two in sync). Layer 1 of the named-fact registry — see the long rationale
# in the POSIX hook and .chezmoidata/facts.yaml.
#
# Every one of the five cached facts is Linux-specific (a PCI vendor scan under
# /sys, systemd-detect-virt, a systemd default target), so on
# Windows their actual probe results are all FALSE. These are platform results,
# distinct from the fail-safe defaults used when no cache exists at all.
# The file is still WRITTEN rather than skipped, because .chezmoitemplates/
# facts.tmpl must have something to read: its `include` is stat-guarded and would
# degrade to the registry's per-fact absent defaults, but an actually-present
# cache keeps the Windows render on the same code path as every other host and
# preserves the real all-false Windows probe results.
function Write-FactsCache {
    $cacheHome = if ($env:XDG_CACHE_HOME) { $env:XDG_CACHE_HOME } else { Join-Path $HOME '.cache' }
    $cacheDir = Join-Path $cacheHome 'chezmoi'
    $cacheFile = Join-Path $cacheDir 'facts.yaml'
    # Never fail the hook over a cache write (rule 2 in the POSIX counterpart):
    # a read-only profile dir must not take down `chezmoi diff`.
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        New-Item -ItemType Directory -Path $cacheDir -Force -ErrorAction Stop | Out-Null
        $lines = @(
            '# Generated by .install-prerequisites.ps1 (chezmoi read-source-state.pre hook).'
            '# Rewritten once per chezmoi command; read by .chezmoitemplates/facts.tmpl.'
            '# Do NOT edit — every value here is a probe result, not a setting.'
            '# Windows: all five cached facts probe Linux-only mechanisms, so all are false.'
            'headless: false'
            'intelGpu: false'
            'nvidia: false'
            'virt: false'
            'vm: false'
        )
        # PowerShell 5.1's `Set-Content -Encoding utf8` prepends a BOM. facts.tmpl
        # shape-checks from byte zero before parsing, so that BOM would discard the
        # otherwise-valid cache forever. Write one newline-terminated UTF-8 string
        # explicitly with the BOM-less encoder; LF is accepted alongside CRLF.
        $text = ($lines -join "`n") + "`n"
        [System.IO.File]::WriteAllText(
            $cacheFile,
            $text,
            (New-Object System.Text.UTF8Encoding $false)
        )
    } catch {
        Write-Stderr "install-prerequisites.ps1: cannot write $cacheFile; hook facts will use their registry fail-safe defaults this run."
    } finally {
        $ErrorActionPreference = $previous
    }
}

# chezmoi calls the GitHub API while reading the source state (fetching the
# .chezmoiexternals repos) and again during provisioning (release assets). It
# authenticates with the first of these tokens it finds — CHEZMOI_GITHUB_ACCESS_TOKEN,
# then GITHUB_ACCESS_TOKEN, then GITHUB_TOKEN. With none set, those calls fall back
# to GitHub's anonymous 60-requests/hour-per-IP limit and a fresh apply can fail
# mid-read with an opaque HTTP 403, so require a token up front.
function Confirm-GitHubToken {
    if ($env:CHEZMOI_GITHUB_ACCESS_TOKEN -or $env:GITHUB_ACCESS_TOKEN -or $env:GITHUB_TOKEN) {
        return $true
    }
    Write-Stderr 'install-prerequisites.ps1: no GitHub API token in the environment.'
    Write-Stderr 'chezmoi is about to read the source state, which calls the GitHub API;'
    Write-Stderr 'without a token it shares the anonymous 60-request/hour limit and a fresh'
    Write-Stderr 'apply can fail. Inject a PAT from 1Password, then re-run in the same shell:'
    Write-Stderr '  $env:GITHUB_TOKEN = op read "op://Private/GitHub/PAT"'
    return $false
}

# Install a winget package by its exact ID if it is not already present. Mirrors
# the shell script's `rpm -q` / `dpkg -s` guard + install so re-runs are cheap.
# `--exact` matters: a substring `list --id AgileBits.1Password` would also match
# the CLI package and wrongly report the desktop app as installed.
function Install-WingetPackage {
    param([Parameter(Mandatory = $true)][string] $Id)

    if ((Invoke-NativeExitCode -FilePath 'winget' -Arguments @('list', '--exact', '--id', $Id)) -eq 0) {
        return
    }
    Write-Stderr "install-prerequisites.ps1: installing $Id via winget ..."
    # --accept-*-agreements is winget's non-interactive `-y`; --source winget and
    # --exact match the IDs precisely. UAC elevation, if the installer needs it, is
    # a separate OS prompt not suppressed here.
    & winget install --source winget --exact --id $Id `
        --accept-package-agreements --accept-source-agreements
    if ($LASTEXITCODE -ne 0) {
        throw "install-prerequisites.ps1: winget failed to install $Id (exit $LASTEXITCODE)."
    }
}

# Windows install path, all via winget: the 1Password desktop app + CLI; Git for
# Windows + GitHub CLI + Git LFS (chezmoi drives git to fetch .chezmoiexternals);
# then mise. zsh from the Linux script stays omitted — it is Unix-only.
function Install-Prerequisites {
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-Stderr 'install-prerequisites.ps1: winget (App Installer) not found on PATH.'
        Write-Stderr 'Install "App Installer" from the Microsoft Store (or Windows updates), then re-run.'
        exit 1
    }

    Install-WingetPackage -Id 'AgileBits.1Password'
    Install-WingetPackage -Id 'AgileBits.1Password.CLI'
    # Git.Git before GitHub.GitLFS: the Git LFS installer runs `git lfs install`,
    # which needs git on PATH.
    Install-WingetPackage -Id 'Git.Git'
    Install-WingetPackage -Id 'GitHub.cli'
    Install-WingetPackage -Id 'GitHub.GitLFS'
    Install-WingetPackage -Id 'jdx.mise'

    # winget wrote PATH to the registry but not to this process; re-read it so the
    # tools we just installed resolve for the auth checks below.
    Update-SessionPath
}

# Unit-test seam: let a harness dot-source this file for its functions without
# running the installer below (mirrors the shell script). No-op in normal
# execution (variable unset).
if ($env:_INSTALL_PREREQUISITES_TEST_SOURCE) { return }

# Seed the config-secrets key early (best-effort), BEFORE the fast path — a
# fully provisioned host still refreshes it on its next command. Mirrors the
# POSIX hook (no container branch, Windows has none). NOTE: like the POSIX side,
# this hook runs AFTER chezmoi renders .chezmoi.toml.tmpl, so it is not what a
# first-init prompt depends on — the config template's prompt path seeds the key
# itself (config-secrets-key-ensure.tmpl, Linux-only). No Windows template
# consumes the key today; this keeps the credential-store infra in lockstep.
Confirm-ConfigSecretsKey

# Refresh the host-fact cache the templates read. Must precede the fast path — a
# provisioned host exits there and every chezmoi command still needs the file to
# exist (mirrors the POSIX hook).
Write-FactsCache

# Fast path: nothing to do once mise is present and `op` can resolve secrets.
# Keeps re-runs cheap — chezmoi invokes this hook on every init / apply.
if ((Get-Command mise -ErrorAction SilentlyContinue) -and (Test-OpReady)) {
    exit 0
}

Install-Prerequisites

# Packages are installed now, but on a fresh device `op` still is not signed in
# (installing the app/CLI does not authenticate it), so chezmoi would fail on the
# first `onepasswordRead`. Block until the user enables the 1Password CLI
# (interactive), or fail fast with guidance (non-interactive / headless).
if (-not (Confirm-OpAuthenticated)) { exit 1 }

# With `op` authenticated, chezmoi's very next step is to read the source state
# over the GitHub API. Require a token now — placed after op auth so the `op read`
# in the guidance actually works — instead of letting the read hit a rate limit.
if (-not (Confirm-GitHubToken)) { exit 1 }

exit 0
