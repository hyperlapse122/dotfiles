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

## Opt-in CA-file Fallback

On macOS and Linux, explicit enrollment can add CA certificates for Requests-based clients and file-based curl. This path uses an application PEM bundle; it does not install certificates into OS trust stores or change Java, Node, Bun, Go, or Windows native trust behavior.

The public-root input is curl's [Mozilla PEM bundle](https://curl.se/docs/caextract.html), downloaded directly from `https://curl.se/ca/cacert.pem`. The committed pin identifies revision `2026-11-05` with SHA-256 `427c064216761a1e72a8b30f0d954d08cb6e4435a82091fb865afd20c8497285`. Its original bytes, including UTF-8 certificate names and comments, form the public prefix; managed CA certificates are appended after DER deduplication. The generated bundle is private at `~/.local/share/dotfiles/ca/bundle.pem`.

Enroll a PEM file containing only CA certificates using the initialized repository GPG configuration:

```sh
mise exec -- python scripts/ca-files.py import --id corporate --pem-file /outside/repo/corporate-ca.pem
mise run apply
```

The importer validates complete certificates and their CA status, encrypts them to the repository recipient, then decrypt-verifies the result before publication. Only `home/.secrets/ca-certificates.json.asc` belongs in Git. Certificate names and PEM content remain inside that ciphertext, and the external input is retained. Never import a private key or rely on this operation to verify that an organization is authorized to issue certificates for your traffic.

Select the bundle for one child process:

```sh
dotfiles-ca requests -- python your_requests_client.py
dotfiles-ca curl -- https://your-private-endpoint.example
```

Requests mode sets `REQUESTS_CA_BUNDLE` only for the child. This is an explicit choice to replace an inherited Requests bundle for that invocation; a client's explicit `verify=` setting still controls its own request. Curl mode supplies `--cacert` and removes inherited file/directory CA overrides only from that child. Explicit later curl flags can override the wrapper's selection. Neither mode exports `SSL_CERT_FILE`, `SSL_CERT_DIR`, `CURL_CA_BUNDLE`, or Requests settings into the parent shell, and neither adds an insecure option. Normal native-trust commands outside the wrapper keep their existing behavior. When a bundle is missing, selection fails instead of bypassing verification.

Re-enroll an existing ID to rotate its CA. Remove an ID, then apply, to rebuild from current public roots and the remaining enrolled certificates:

```sh
mise exec -- python scripts/ca-files.py remove --id corporate
mise run apply
```

An empty enrollment produces the public-only bundle. Unrelated files in the managed directory survive. Invalid certificates, missing public input, or decryption failure leave the last valid bundle unchanged. Without an enrollment file, bootstrap and apply do not decrypt CA data or provision fallback files.

Enrolled Unix hosts prepare that public PEM through the shared external-asset cache before CA reconciliation. The preparation owns only `public-roots.pem`; the generated private bundle and unrelated CA files are preserved. Unchanged applies reuse preparation, and missing public-root files are repaired from the cache. A checksum failure stops preparation before replacing the installed public input or combined bundle. See [external asset preparation](../maintenance/chezmoi-source.md#external-asset-preparation) for full verification and refresh commands.

### Refreshing the public-root pin

The download URL follows curl's current bundle, while the committed digest admits only the reviewed revision. An upstream update can therefore make a cold download or forced refresh fail until the pin is updated; an intact prepared cache remains reusable. Refreshing assets does not accept a new checksum automatically.

1. Open curl's [CA Extract page](https://curl.se/docs/caextract.html) over verified HTTPS and identify the current dated revision. Download `https://curl.se/ca/cacert.pem` and its [published SHA-256](https://curl.se/ca/cacert.pem.sha256) into a temporary directory using normal TLS verification.
2. Compute the downloaded PEM's SHA-256, for example with `mise exec -- python -c 'import hashlib, pathlib; print(hashlib.sha256(pathlib.Path("cacert.pem").read_bytes()).hexdigest())'` from that directory. Require equality with the published checksum. Check its header date and compare its bytes or digest with the dated PEM and checksum linked by curl's revision table. If the live bundle changed during verification, download and verify again.
3. Review the upstream revision, then update `version` and `sha256` together in `home/.chezmoidata/ca-files.json`. Keep `url` as `https://curl.se/ca/cacert.pem`. Do not replace the pin merely with a digest reported by a failed preparation.
4. Run `mise exec -- python -m unittest discover -s tests -p test_ca_files.py` and `mise exec -- python -m unittest discover -s tests -p test_external_assets.py`. Commit the reviewed pin. Use `mise run apply` when ready to apply personal configuration; use `mise run assets:refresh` only when a forced download is also intended.

Synthetic local TLS tests verify that the combined bundle accepts an enrolled CA while the public-only bundle rejects it. They also check public-root preservation, rejection of leaf/private-key/partial PEM input, repeated apply, certificate removal, and child-only environment selection. These tests do not install an organization's CA or prove that a real enterprise endpoint has the expected chain.
