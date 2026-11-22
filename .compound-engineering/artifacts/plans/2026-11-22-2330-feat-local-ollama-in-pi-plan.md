---
title: Local Ollama models in Pi - Plan
type: feat
date: 2026-11-22
topic: local-ollama-in-pi
artifact_contract: ce-unified-plan/v1
product_contract_source: ce-brainstorm
execution: code
---

# Local Ollama models in Pi - Plan

## Goal Capsule

- **Objective.** After a restart, the owner can open Pi on either personal computer and get an offline response from a local model.
- **Means.** Run Ollama on the NixOS desktop and the MacBook Pro.
- **Product authority.** The owner confirmed the requirements below for both machines.
- **Delivery.** One PR covers both production hosts. Repository checks run before delivery. The owner applies the configuration and verifies hardware behavior.
- **Open blockers.** None.

## Product Contract

### Summary

Add Ollama as an optional provider in Pi. Both computers run Ollama under the owner's account and keep a model on disk for offline use.

### Key Decisions

- **Independent hosts.** Governs R1, R2. (session-settled: user-directed — chosen over installing on one machine: the owner wants local inference on either computer.)
- **Platform-specific startup.** Governs R1. (session-settled: user-directed — the owner chose CLI-only operation on NixOS over adding Alpaca and accepted login-time startup for the official Mac app.)
- **Opt-in provider.** Governs R4. (session-settled: user-directed — chosen over making Ollama the default: ordinary Pi sessions should still start with Synthetic.)
- **Load on demand.** Governs R3. (session-settled: user-directed — chosen over preloading at boot: the owner accepts the first-load delay to keep memory available before use.)

### Requirements

**Startup and model availability**

- R1. Run the local server as a user service on each machine.
  - **NixOS desktop.** Install only the Ollama CLI and service. The owner's systemd user service starts at boot, before the first login. Exclude Alpaca and other Ollama desktop clients.
  - **MacBook Pro.** Install the official Ollama desktop app as a login item. At login, the app starts its local server in the owner's session.
- R2. Initial setup puts a usable model on each machine's disk so later boots and local inference work offline.
- R3. Ollama loads the model into memory when it receives the first inference request after boot.

**Model selection in Pi**

- R4. Keep Synthetic as Pi's default and offer the local Ollama model alongside the existing model choices.
- R5. Selecting Ollama sends inference requests only to the model on the same machine. If it cannot answer, Pi reports the error without retrying through a cloud provider.

### Acceptance Examples

- AE1. **Covers R1, R2, R3, R4.** After an offline reboot of the configured NixOS desktop, the owner's Ollama service is running before login. Log in, open Pi, select Ollama, and send a prompt. The first request loads the model from disk and receives a reply.
- AE2. **Covers R5.** With network access available and the local service unavailable, a prompt sent to the selected Ollama model produces an error. No cloud model receives the prompt.
- AE3. **Covers R1, R2, R3, R4.** After an offline reboot of the configured MacBook Pro, log in. The official app starts its server automatically. Open Pi, select Ollama, and send a prompt. The first request loads the model from disk and receives a reply.

## Planning Contract

Product Contract preserved. Model choice was deferred to planning.

- KTD1. Provision `qwen3:4b` on the RTX 3060 and `qwen3-coder:30b` on the 64 GiB Mac. These tool-capable local tags require about 2.5 GB and 19 GB of disk respectively. Use one model definition per host kind for both installation and Pi. Create a Pi-specific local model from the downloaded weights with a 32,768-token context on NixOS and a 65,536-token context on macOS. Set the same context in Pi, allow 4,096 output tokens with Ollama’s supported `max_tokens` field, and size Pi's model-specific compaction reserve and retained history within that window. This avoids the desktop server’s 4K default and leaves other models alone. [Linux model](https://ollama.com/library/qwen3:4b) · [Mac model](https://ollama.com/library/qwen3-coder:30b)
- KTD2. Use the owner's systemd user manager with lingering on NixOS. Give the service the CUDA build when the existing CUDA trait is active. Lingering starts the owner's default target at boot and keeps it active across logouts. Move minikube to the graphical session target and couple its stop to session exit so lingering does not run a cluster before desktop login or after logout. Inspect the other default-target services and retain headless services that require no graphical session.
- KTD3. Install Homebrew's `ollama-app` cask on the production Mac. Bootstrap the official bundle from an owner LaunchAgent in the Aqua session so the app can register its own login item. Merge the cloud-disable key into the user’s Ollama server settings before first launch. Use the app's server for both provisioning and Pi. Honor macOS background-item approval. [Cask](https://formulae.brew.sh/cask/ollama-app) · [Login item](https://docs.ollama.com/faq#how-can-i-stop-ollama-from-starting-when-i-login-to-my-computer)
- KTD4. Configure local-only Ollama and use a loopback endpoint. Register the local tag using Pi's OpenAI-compatible provider with a literal placeholder key. The existing defaults and managed cloud providers keep their current behavior. Bootstrap profiles omit the Ollama integration. [Pi provider example](https://docs.ollama.com/integrations/pi#manual-setup) · [Local-only mode](https://docs.ollama.com/faq#how-do-i-disable-ollamas-cloud-features)
- KTD5. Check for the selected model in the running server's own store before pulling. Provision in the user session independently of an interactive Pi process or a Home Manager rebuild. A successful first pull completes online setup. On subsequent starts use the cached model. Use restart-on-failure with a delay on the Linux oneshot and unsuccessful-exit retry on the Mac LaunchAgent. Check model readiness without going through an HTTP proxy. Provisioning does not send an inference request.

## Implementation Units

### U1. Start Ollama and provision the local model

**Covers R1–R3, AE1, AE3.** Add the production host declarations, shared model definition, owner-scoped provisioning and service configuration. Extend the existing Homebrew app inventory and materialized host checks. Preserve unrelated mutable Ollama settings. Document when initial online setup completes and how to recover from a failed pull or a disabled Mac login item.

### U2. Make the local model selectable in Pi

**Covers R4, R5, AE1–AE3.** Extend the materialized model catalog and enabled list in `home/h82/agents/pi.nix` using U1's model definition. Keep the normal production Synthetic credential publication intact. Exercise the installed Pi runtime and actual settings activation using fake credentials. Keep Pi's loopback endpoint outside any configured HTTP proxy. Drive a scripted tool-call round trip against a local OpenAI-compatible stub, then exercise failure with other providers configured. Separately verify real prompt capacity and tool calling on each host.

## Verification Contract

- Run the existing Pi checks and relevant materialized Linux and Darwin output checks. Inspect the startup target, owner, selected package, model, login behavior and bootstrap exclusions. Exercise the provisioning helper with a scratch model store or a stubbed local service for missing, cached and interrupted pulls.
- Run the project pre-push checks and require current-head full CI. Linux boot behavior belongs to a Linux builder or VM. Hardware acceleration, the macOS login item and actual offline replies after a reboot need the respective host.

## Definition of Done

A fresh production setup provisions the selected model. After setup, each host satisfies its offline acceptance example and rejects a failed local inference request without sending it to a cloud model. Report physical-host evidence separately from repository and VM checks.
