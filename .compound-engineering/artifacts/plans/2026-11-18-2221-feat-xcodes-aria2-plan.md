---
title: Parallel Xcode downloads - Plan
type: feat
date: 2026-11-18
artifact_contract: ce-unified-plan/v1
product_contract_source: ce-plan-bootstrap
execution: code
---

# Parallel Xcode downloads - Plan

## Goal Capsule

- **Objective** Reduce the time a managed Mac waits to download a new Xcode archive.
- **Means** Enable the pinned Xcodes CLI's parallel aria2 downloader (KTD1).
- **Authority** The request covers repository changes, local verification with fake credentials, and one pull request.

## Product Contract

### Summary

macOS production activation uses aria2 when Xcodes needs to download a new archive.

### Problem Frame

Activation currently asks Xcodes to use its single-stream URLSession downloader. The Nix package already ships with aria2 available to the CLI.

### Requirements

- R1. A managed Xcode installation that needs a download uses aria2 automatically.
- R2. Apple download cookies stay out of process arguments and normal output. The downloader observes their domain, path, and secure attributes.
- R3. Downloads keep TLS certificate verification enabled and trust the managed inspection CA on hosts that use one. Xcode selection follows a successful install and verification.

## Planning Contract

### Key Technical Decisions

- KTD1. Enable downloader discovery in the existing Nix-wrapped Xcodes package. The wrapper already puts a pinned aria2 on the child process's path.
- KTD2. Patch the pinned download service to hand aria2 scoped cookies through its native cookie-file interface. A user-only file in an installer-owned temporary directory keeps the cookies out of argv and gives the installer a way to remove them after interruption. Raw headers in the pinned service bypass aria2's cookie scoping on redirects.
- KTD3. Set `SSL_CERT_FILE` from the machine's managed TLS configuration in the activation step because nix-darwin clears the shell environment. Pass it to aria2 as its CA bundle and invoke aria2 with `--no-conf` so user download settings cannot turn off verification or log the cookies.

### High-Level Technical Design

During an archive download, Xcodes obtains eligible cookies for the archive URL. The patched service hands aria2 their attributes in a private cookie file alongside the optional CA bundle path. aria2 selects cookies per request and downloads the archive. Download completion releases the file. The Python installer removes the temporary directory when the CLI exits or is interrupted.

## Implementation Units

### U1. Protect cookies in the packaged downloader

- **Covers** R2 and the trust portion of R3.
- **Files** `packages/macos-xcode.nix`, the downstream XcodesKit patch in `packages/`, and a Swift fixture in `tests/`.
- **Approach** Apply the patch to the writable copy of the vendored XcodesKit dependency. Preserve the CLI's existing connection and progress handling.
- **Test scenarios** A fake downloader receives a scoped test cookie in a private file with only the path in argv. Exercise normal exit and a failed download, confirming cleanup. Verify a supplied CA bundle reaches the downloader.
- **Verification** Run a focused Swift test in the patched Xcodes derivation's check phase. Call the download service with fake cookies and an executable aria2 stub.

### U2. Enable aria2 during macOS activation

- **Covers** R1 and the selection portion of R3. Depends on U1.
- **Files** `modules/darwin/xcode.nix`, `scripts/macos-xcode.py`, `tests/darwin-config.nix`, `tests/test_darwin_provisioning.py`, and `docs/macos.md`.
- **Test scenarios** The fake installer invocation permits the default downloader and its private temporary directory is gone after interruption. The rendered activation passes the managed CA bundle under a clean environment when TLS inspection is configured.
- **Verification** Run the Darwin configuration check with fake tools.

## Verification Contract

Use the packaged downloader check for the cookie and CA handoff. Use the Darwin provisioning check for the managed command. Record actual Apple CDN throughput separately from repository verification.

## Definition of Done

Production activation enables the patched aria2 downloader and the two affected checks pass. The pull request reports the available CI evidence and whether a live Apple download was measured.

### Sources

- [Pinned XcodesKit download service](https://github.com/XcodesOrg/XcodesKit/blob/4d3c6093980978b74c3fa42fc1b90cd1c34ac911/Sources/XcodesKit/Services/Aria2DownloadService.swift)
- [aria2 cookie and TLS options](https://aria2.github.io/manual/en/html/aria2c.html)
