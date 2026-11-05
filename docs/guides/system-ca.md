# Native System CA Trust

This guide describes how dotfiles enables operating system certificate authority (CA) trust for development runtimes via `NODE_USE_SYSTEM_CA=1`, how environment variables are activated per platform, and how to verify effective TLS trust.

## Overview

In corporate, enterprise, or deep-packet inspection (DPI) environments, organizations often install custom root certificates into the operating system certificate store. Modern runtimes such as Node.js and Bun historically bundled their own static Mozilla CA lists, ignoring host-installed root certificates.

Dotfiles enables native OS certificate store discovery without disabling TLS verification or hostname checks:
- Persists `NODE_USE_SYSTEM_CA=1` in user environment configuration.
- Configures Git for Windows to use Windows Schannel (`http.sslBackend = schannel`).
- Leaves native defaults unchanged for tools that already query the OS store.
- Does not modify machine-wide settings or install root certificates itself (certificates must already be installed in Windows Root Store, macOS Keychain, or Linux system paths).

## Runtime Support Matrix

| Target | Version / Prerequisites | Managed Behavior |
|---|---|---|
| **Node.js** | 22.19.0+ (in 22.x) or 24.6.0+ (in 24.x) | Queries system root certificates in addition to bundled roots |
| **Bun** | 1.2.23 or newer | Queries system root certificates in addition to bundled roots |
| **Standalone omp** | Bundled embedded Bun | Inherits `NODE_USE_SYSTEM_CA=1` automatically |
| **Python standard library** | Supported Python 3 releases | Windows loads CryptoAPI stores; Linux uses system OpenSSL paths |
| **pip** | pip 24.2+ on Python 3.10+ | Uses system certificates alongside `certifi` |
| **Requests** | All versions | Defaults to `certifi`; no automatic OS store integration |
| **Java JSSE** | All versions | No JVM-wide truststore override applied |
| **Git HTTPS** | Git for Windows (2.14.0+) | Uses Schannel backend; TLS and revocation checks remain enabled |
| **curl** | Windows Schannel / native libcurl | Uses OS trust by default; no global insecure flag added |
| **Go tools** | Go 1.20+ | Uses Windows/macOS CryptoAPI and Linux system CA bundles |

## Environment Activation by Operating System

Because environment variables must reach both GUI desktop launchers and command-line shells, dotfiles activates `NODE_USE_SYSTEM_CA=1` through platform-native user session mechanisms:

### Windows

- **Method:** Writes `NODE_USE_SYSTEM_CA=1` under `HKCU\Environment`.
- **Activation:** Sign out and back in to Windows to ensure all desktop applications, terminals, and IDEs inherit the new value. (A new tab in an existing terminal may retain stale parent environment).

### Linux

- **Method:** Installs `~/.config/environment.d/60-native-system-ca.conf` and adds an export block to `.profile`, `.bashrc`, and `.zshenv`.
- **Activation:**
  ```sh
  systemctl --user daemon-reload
  ```
  Restart your graphical desktop session or affected application launchers.

### macOS

- **Method:** Installs a LaunchAgent at `~/Library/LaunchAgents/com.hyperlapse.native-system-ca.plist` and adds an export block to Unix shell startup files.
- **Activation:** Log out and log back in to Aqua. Verify the LaunchAgent environment:
  ```sh
  launchctl getenv NODE_USE_SYSTEM_CA
  ```
  This should print `1`.

## Verifying Effective Trust

Verify effective trust by running an actual HTTPS command through an affected tool outside the repository:

```sh
# Probe public update endpoint without updating
omp update --check
```

### Troubleshooting Conflicting Variables

If TLS connections continue to fail despite OS trust:
1. Inspect inherited override variables:
   ```sh
   echo $NODE_EXTRA_CA_CERTS
   echo $SSL_CERT_FILE
   echo $SSL_CERT_DIR
   ```
2. Some tools (such as Go) switch from OS CryptoAPI to file-based lookups when `SSL_CERT_FILE` or `SSL_CERT_DIR` is set.
3. In `omp`, explicit request-level CA configurations may conflict if `NODE_EXTRA_CA_CERTS` points to a missing or invalid bundle.
4. **Never resolve certificate issues by disabling TLS verification (`NODE_TLS_REJECT_UNAUTHORIZED=0`).** Ensure the issuing enterprise root CA is installed in your operating system's root store.
