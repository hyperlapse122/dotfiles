---
title: T3 Code's Antigravity ACP server finds no CA bundle on NixOS and hangs every session silently
date: "2026-10-06"
category: integration-issues
module: T3 Code desktop package and its Antigravity provider
problem_type: integration_issue
component: tooling
severity: high
symptoms:
  - "A T3 Code thread or delegated task on the Antigravity provider never answers; even \"hi\" gets no reply and no error"
  - "T3's provider event log shows initialize, authenticate, session/new, and session/prompt started, then zero session/update events"
  - "The thread reports no pending approval request (pendingRequestCount 0), and switching the runtime mode to Full access hangs the same way"
  - "agy_acp_server.par.ERROR logs CCPAConnectionError: Network connection failed to CCPA API: [SSL: CERTIFICATE_VERIFY_FAILED] unable to get local issuer certificate"
  - "The standalone agy CLI answers normally, and its conversation list never shows the T3 sessions"
root_cause: config_error
resolution_type: config_change
related_components:
  - infrastructure
retire_when: "The Antigravity ACP server T3 downloads stops embedding an OpenSSL with a nonexistent default CA path; check by running a minimal ACP client against ~/.t3/tools/antigravity-acp/linux-x64/versions/*/agy_acp_server.par with T3's GEMINI_HOME and no SSL_CERT_FILE, and see whether session/prompt returns session/update chunks"
tags: ["t3code", "antigravity", "acp", "ssl-cert-file", "ca-bundle", "openssl", "bubblewrap", "silent-hang"]
---

# T3 Code's Antigravity ACP server finds no CA bundle on NixOS and hangs every session silently

## Problem

T3 Code runs its Antigravity provider through an ACP server it downloads itself, `~/.t3/tools/antigravity-acp/linux-x64/versions/<hash>/agy_acp_server.par`. That binary embeds a Python with its own OpenSSL, and the OpenSSL's compiled-in default CA path, `/opt/pyca/cryptography/openssl/cert.pem`, does not exist on NixOS. Every model request fails certificate verification. The server keeps retrying and never reports the failure to T3, so every Antigravity session hangs with no output. (`home/h82/t3code.nix` has since retired `providerInstances.antigravity` in favor of the unified `omp` ACP instance, while `packages/t3code.nix` keeps `SSL_CERT_FILE` in the desktop sandbox so any vendored OpenSSL binary T3 Code downloads or spawns on NixOS still finds the system CA bundle.)

## Symptoms

- An Antigravity thread in T3, or an Antigravity task started with `delegate_task`, never answers, not even "hi".
- T3's per-thread provider event log (`~/.t3/userdata/logs/provider/events.<thread>.log`) records `initialize`, `authenticate`, `session/new`, and `session/set_config_option` as succeeded and `session/prompt` as started, then no `session/update` at all.
- The thread has no pending approval request, and Full access hangs exactly like Supervised.
- The real error appears only in the server's own glog files, under `~/.t3/userdata/antigravity-tmp/<id>/run-*/agy_acp_server.par.{INFO,ERROR}`: `SSL: CERTIFICATE_VERIFY_FAILED ... unable to get local issuer certificate`, raised from `ccpa_client.stream_generate_content` and logged by `proxy_server.py` as "Proxy failed to connect to CCPA API".

## What Didn't Work

- **Blaming the runtime mode.** The first run used Supervised (`approval-required`), and the hang looked like an approval waiting where nobody could see it. Re-running with Full access hung identically, and the thread's `pendingRequestCount` was 0 throughout.
- **Blaming Google authentication.** A Google sign-in prompt appeared during debugging and was completed. Sessions still hung afterwards, because `authenticate` had been succeeding all along and the failure came later, at the model call.
- **Comparing with the `agy` CLI (since removed).** `agy` answered "hi" and listed its conversations, but none from T3. It was a different binary with a different state directory (`~/.gemini/antigravity-cli/`), while T3 pointed the ACP server at its own `GEMINI_HOME` under `~/.t3/userdata/providers/antigravity/<hash>`. A working `agy` said nothing about T3's server.
- **Attaching `strace` to the hung server.** `kernel.yama.ptrace_scope = 1` refuses attaching to a process that is not your child, so the CA paths the server tries could not be traced live. Finding the server's open log file descriptors under `/proc/<pid>/fd` led to the glog files instead.
- **Checking the CA bundle itself.** `openssl s_client` verified the Google endpoint against both `/etc/ssl/certs/ca-certificates.crt` and the `cacerts` file the server extracts next to its logs. The bundle was fine; the server simply never loaded it. Grepping the `.par` for CA paths found `/opt/pyca/cryptography/openssl/cert.pem` alongside `SSL_CERT_FILE`.

## Solution

Point `SSL_CERT_FILE` at the system bundle inside the T3 Code desktop wrapper's bubblewrap sandbox, which every provider process T3 starts inherits (the `extraBwrapArgs` list in `packages/t3code.nix`):

```nix
extraBwrapArgs = [
  "--setenv T3CODE_DISABLE_AUTO_UPDATE 1"
  ''--setenv CONTAINER_HOST "unix://$XDG_RUNTIME_DIR/podman/podman.sock"''
  "--setenv SSL_CERT_FILE /etc/ssl/certs/ca-certificates.crt"
];
```

Inside the sandbox, `/etc/ssl/certs/ca-certificates.crt` is the host's `/etc/static` symlink (observed through `/proc/<server-pid>/root` in this session), so the server reads the same bundle NixOS builds from `security.pki`. The `t3code` check in `flake.nix` asserts the wrapper sets it (its `expect_setenv SSL_CERT_FILE` assertion). The change takes effect after a rebuild and a T3 Code restart, because providers inherit the environment of the running app.

Historically, when the same runtime was started outside T3 Code from a terminal session, it did not inherit that sandbox: its since-removed `agy_acp_server.par` wrapper on `PATH` (`packages/antigravity-acp-path.nix`) set `SSL_CERT_FILE` on Linux when the caller left it unset, and the former `antigravity-acp-path` check ran that wrapper against a stub runtime.

## Why This Works

OpenSSL reads `SSL_CERT_FILE` before falling back to its compiled-in default, so the embedded Python's `ssl.create_default_context()` loads the system bundle instead of the missing `/opt/pyca/...` file. A standalone ACP client run against the same server binary with T3's `GEMINI_HOME` proved it: with `SSL_CERT_FILE` set, `session/prompt` streamed "Hello! How can I help you today?" within five seconds; without it, the same prompt produced nothing for 40 seconds. After the rebuild and restart, a delegated Antigravity task completed through T3.

## Prevention

- **When an ACP provider in T3 hangs after `session/prompt`, read the provider's own logs first.** T3's event log only shows that no `session/update` arrived. For Antigravity, the cause is in `~/.t3/userdata/antigravity-tmp/<id>/run-*/agy_acp_server.par.ERROR`. In this session the run directories were gone once the server processes exited, so read them while the hung session is still alive.
- **Reproduce outside T3 with a minimal ACP client** that spawns the server with T3's environment (`GEMINI_HOME`, `ANTIGRAVITY_HARNESS_PATH`, `AGY_ACP_FORCE_FILE_STORAGE`, all readable from `/proc/<pid>/environ`) and sends `initialize`, `authenticate`, `session/new`, and `session/prompt` over stdio. Toggling one variable between runs turns a guess into a proof.
- **Expect vendored binaries that bundle OpenSSL to miss NixOS's CA paths.** Check a new downloaded tool's outbound TLS once, and set `SSL_CERT_FILE` in its wrapper when its default path does not exist here.
- **Cancelling a delegated Antigravity task leaves its server running.** In T3 Code 0.0.46-nightly, `task_cancel` stopped the task, but its `agy_acp_server.par` and `localharness_external` processes stayed alive until killed by hand. Check for them before reusing a debugging session.
