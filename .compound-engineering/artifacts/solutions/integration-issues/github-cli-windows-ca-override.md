---
title: GitHub CLI CA bundle overrides Windows platform trust
date: 2026-11-04
category: integration-issues
module: GitHub CLI
problem_type: integration_issue
component: tooling
severity: medium
framework_version: "gh 2.103.3, built with Go 1.27.3"
symptoms:
  - "GitHub CLI web login fails with x509 certificate signed by unknown authority"
  - "The requested CA is already trusted in the Windows current-user root store"
root_cause: config_error
resolution_type: environment_setup
retire_when: "Go changes or removes x509sslcertoverrideplatform; check the runtime release notes and versioned crypto/x509 root loading before reusing this workaround."
tags: [github-cli, windows, tls, certificates, environment, go]
---

# GitHub CLI CA bundle overrides Windows platform trust

## Problem

GitHub CLI could not start its web login even though Windows already trusted the requested corporate CA.
An inherited `SSL_CERT_FILE` selected a bundle containing only that CA, replacing the platform trust path for the installed Go runtime.

## Symptoms

- The device-code request failed with `tls: failed to verify certificate: x509: certificate signed by unknown authority`.
- A Windows TLS chain inspection reported no validation errors and a normal public certificate chain for GitHub.
- The installed GitHub CLI binary identified Go 1.27.3 and contained the `x509sslcertoverrideplatform` setting.

## What Didn't Work

Re-registering the already-trusted CA in `CurrentUser/Root` did not make GitHub CLI login succeed.
That store was not the trust source selected by the inherited certificate-file override.

## Solution

Temporarily set `GODEBUG=x509sslcertoverrideplatform=0` for the GitHub CLI process.
The successful login was launched from a child PowerShell process with that setting; it did not change persistent environment settings or disable TLS verification.

For a temporary setting in an existing PowerShell session, preserve and restore the previous value:

```powershell
$previousGodebug = $env:GODEBUG
try {
    $env:GODEBUG = "$previousGodebug,x509sslcertoverrideplatform=0".TrimStart(',')
    mise exec -- gh auth login --hostname github.com --web --clipboard
} finally {
    $env:GODEBUG = $previousGodebug
}
```

The CA must already be trusted by Windows when platform verification needs it.
This setting selects that trust source; it does not add a CA to a store.

## Why This Works

[Go 1.27.3 root loading](https://github.com/golang/go/blob/go1.27.3/src/crypto/x509/root.go) checks `SSL_CERT_FILE` and `SSL_CERT_DIR` on Windows before selecting platform verification.
When either is set, its normal path loads roots from the supplied filesystem locations.
Setting `x509sslcertoverrideplatform=0` selects the platform certificate pool instead.
A single corporate CA file is not equivalent to the Windows store's set of public and enterprise roots.

The observed login completed successfully after this process-local change.
Older advice that Windows Go programs always ignore `SSL_CERT_FILE` does not describe the runtime verified here.

## Prevention

Check inherited certificate-file and certificate-directory overrides before changing Windows trust stores.
Scope an operational workaround to the required process or restore the prior session value afterward; do not commit machine-specific certificate paths or disable certificate verification.
Recheck support against the tool's actual embedded Go version rather than assuming every GitHub CLI release behaves the same way.

## Related Issues

- [GitHub CLI custom CA discussion](https://github.com/cli/cli/issues/1735) contains historical reports; its older platform-specific advice must be checked against the current runtime.
- [GitHub CLI web login options](https://cli.github.com/manual/gh_auth_login).
