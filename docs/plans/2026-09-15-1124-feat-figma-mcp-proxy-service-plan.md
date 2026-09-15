---
title: "Figma MCP User Proxy Service - Plan"
type: feat
date: 2026-09-15
topic: figma-mcp-proxy-service
artifact_contract: ce-unified-plan/v1
product_contract_source: ce-brainstorm
execution: code
---

# Figma MCP User Proxy Service - Plan

## Goal Capsule

- **Objective:** Enable all local agent harnesses to access Figma MCP at its canonical URL `https://mcp.figma.com/mcp` without per-harness OAuth configuration or credential storage.
- **Means:** Deploy a local HTTP/HTTPS forward proxy user service (`figma-proxy`) intercepting `mcp.figma.com:443` via `HTTP_PROXY`, managing Figma OAuth authentication, and injecting Bearer tokens for headerless requests. (KTD1, KTD2)
- **Product authority:** Defines the proxy user service architecture, OAuth lifecycle, HTTP_PROXY environment integration, and certificate trust contract.
- **Open blockers:** None.
- **Execution profile:** Multi-unit TypeScript daemon and CLI package in `packages/figma-proxy`, systemd user service, environment drop-ins, and chezmoi build/manifest integrations.

---

## Product Contract

### Summary

Deploy a local MITM forward proxy user service (`figma-proxy`) running on localhost and bound to user session environment variables (`HTTP_PROXY`, `HTTPS_PROXY`). The proxy intercepts `mcp.figma.com:443` CONNECT requests, dynamically issues TLS certificates trusted by a local Root CA, and injects managed Figma OAuth Bearer tokens when client requests lack authorization headers, while preserving existing client headers and tunneling non-Figma traffic untouched.

### Problem Frame

The remote Figma MCP server (`https://mcp.figma.com/mcp`) requires standard OAuth 2.0 PKCE browser authorization and does not support static Personal Access Tokens. While Claude Code and Codex implement native MCP OAuth flows, other agent harnesses such as Antigravity CLI and omp lack built-in OAuth support. Previous per-harness authentication utilities (`figma-auth`) directly manipulated client databases and configuration files, creating high maintenance overhead and brittle synchronization across harness updates. A forward proxy architecture decouples authentication from individual harnesses, allowing every agent tool to address the canonical Figma endpoint directly.

### Key Decisions

- **Forward proxy via HTTP_PROXY environment variables.** (session-settled: user-directed — chosen over nftables transparent packet redirection: eliminates root firewall requirements while keeping client MCP URL fixed at `https://mcp.figma.com/mcp`) Governs R1, R2, R4.
- **Hybrid OAuth lifecycle.** (session-settled: user-directed — chosen over CLI-only or on-demand-only: supports proactive CLI login and on-demand fallback) Governs R6, R7, R8.
- **Transparent header-preserving passthrough.** (session-settled: user-directed — chosen over forced token override or process-specific bypass: allows Claude/Codex native auth to coexist while injecting for others) Governs R3, R5.
- **Declarative dotfiles integration.** (session-settled: user-directed — chosen over standalone setup script: manages environment configuration and local Root CA trust via chezmoi) Governs R9, R10.
- **Blind tunneling for non-Figma traffic.** Governs R4.

### Actors

- A1. Non-OAuth agent harnesses (Antigravity CLI, omp): issue standard MCP requests to `https://mcp.figma.com/mcp` without credentials.
- A2. OAuth-native agent harnesses (Claude Code, Codex): issue MCP requests with client-managed `Authorization` headers.
- A3. `figma-proxy` daemon: local user service handling HTTP CONNECT, TLS termination for `mcp.figma.com`, token lifecycle, and upstream proxying.
- A4. Figma MCP server (`mcp.figma.com`): remote OAuth-protected MCP service.

### Requirements

**Proxy Architecture & Routing**

- R1. The proxy service must listen on a user-space loopback port (e.g. `127.0.0.1:8888`) as a systemd user service (`figma-proxy.service`).
- R2. User session environment variables (`HTTP_PROXY`, `HTTPS_PROXY`) must route outbound HTTP/HTTPS requests through the local proxy service.
- R3. The proxy must preserve the client-facing endpoint URL as `https://mcp.figma.com/mcp` without requiring path or host changes in MCP client configurations.
- R4. For any CONNECT request targeting a non-Figma host, the proxy must establish a raw TCP tunnel to the upstream destination without terminating or inspecting TLS.
- R5. For CONNECT requests targeting `mcp.figma.com:443`, the proxy must terminate TLS using a local dynamic certificate and evaluate incoming HTTP request headers.

**Authentication & Session Management**

- R6. When an incoming request to `mcp.figma.com` contains an existing `Authorization` header, the proxy must forward the header and payload to upstream Figma unmodified.
- R7. When an incoming request to `mcp.figma.com` lacks an `Authorization` header, the proxy must attach a valid `Authorization: Bearer <access_token>` from its managed OAuth session.
- R8. The proxy must maintain OAuth credentials (`tokens.json` in `~/.local/state/figma-proxy/`) with automatic token refresh upon expiry.
- R9. If no valid token exists, the proxy must provide both a manual CLI login command (`figma-proxy login`) and an automatic browser authorization popup when an unauthenticated request arrives.
- R10. The proxy daemon must bypass its own proxy configuration (using `NO_PROXY` or direct socket binding) when initiating outbound connections to Figma to prevent loopback deadlock.

**Certificate Authority & Trust Integration**

- R11. The proxy must generate a local Root CA private key and certificate with 0600 permissions upon first initialization if not already present.
- R12. The Root CA certificate must be installed into the host system trust store (`/etc/pki/ca-trust` / `update-ca-trust`) via chezmoi system configuration.
- R13. User environment configuration (`environment.d`) must export runtime CA variables (`NODE_EXTRA_CA_CERTS`, `SSL_CERT_FILE`) referencing the local Root CA certificate.

### Key Flows

- F1. Transparent token injection for non-OAuth harness
  - **Trigger:** Antigravity or omp sends an MCP request to `https://mcp.figma.com/mcp` without an authorization header.
  - **Actors:** A1, A3, A4
  - **Steps:**
    1. Client issues `CONNECT mcp.figma.com:443` to local proxy via `HTTPS_PROXY`.
    2. Proxy terminates TLS with local `mcp.figma.com` cert and parses incoming HTTP request.
    3. Proxy detects missing `Authorization` header and verifies cached OAuth token validity.
    4. Proxy attaches `Authorization: Bearer <access_token>` and forwards request to upstream Figma MCP.
    5. Upstream response is relayed back to the client.
  - **Outcome:** Client receives successful MCP response without configuring authentication.
  - **Covers:** R1, R2, R3, R5, R7

- F2. Header passthrough for OAuth-native harness
  - **Trigger:** Claude Code or Codex sends an MCP request with an existing `Authorization: Bearer <token>` header.
  - **Actors:** A2, A3, A4
  - **Steps:**
    1. Client issues `CONNECT mcp.figma.com:443` to local proxy via `HTTPS_PROXY`.
    2. Proxy terminates TLS and detects existing client `Authorization` header.
    3. Proxy preserves client header verbatim and forwards request upstream.
  - **Outcome:** Client-managed authentication succeeds without token substitution.
  - **Covers:** R5, R6

- F3. On-demand browser authorization
  - **Trigger:** An unauthenticated request arrives at the proxy when no valid token or refresh token exists.
  - **Actors:** A1, A3, A4
  - **Steps:**
    1. Proxy pauses client request handling and launches the default system browser with the Figma OAuth PKCE URL.
    2. User completes authentication in browser and is redirected to local callback listener.
    3. Proxy exchanges authorization code for tokens, saves state to disk, and resumes paused client request.
  - **Outcome:** Client request succeeds following initial user consent without returning a 401 error.
  - **Covers:** R8, R9

- F4. Blind TCP tunneling for non-Figma traffic
  - **Trigger:** Any local client makes an HTTPS request to an external host (e.g. `api.github.com:443`) via `HTTPS_PROXY`.
  - **Actors:** A3
  - **Steps:**
    1. Proxy receives `CONNECT api.github.com:443`.
    2. Proxy verifies target host is not `mcp.figma.com`.
    3. Proxy opens raw TCP connection to upstream target and pipes client socket directly.
  - **Outcome:** Non-Figma traffic flows securely without TLS inspection.
  - **Covers:** R4

### Visualizations

```mermaid
flowchart TB
    Client["Client Request (Antigravity / Claude / Browser)"] --> Proxy["figma-proxy (127.0.0.1:8888)"]
    Proxy --> IsFigma{"Target == mcp.figma.com?"}
    
    IsFigma -->|No| BlindTunnel["Blind TCP Tunnel (No Decryption)"] --> Internet["Internet (github.com, etc.)"]
    
    IsFigma -->|Yes| MITM["TLS Handshake with Local Root CA"]
    MITM --> HasAuth{"Has Authorization Header?"}
    
    HasAuth -->|Yes (Claude / Codex)| Passthrough["Forward Original Header"]
    HasAuth -->|No (Antigravity / omp)| TokenCheck{"Valid Token in Store?"}
    
    TokenCheck -->|Valid| Inject["Inject Bearer Token"]
    TokenCheck -->|Expired| Refresh["Refresh via OAuth Token Endpoint"] --> Inject
    TokenCheck -->|Missing| BrowserLogin["Trigger Browser PKCE Flow"] --> Inject
    
    Passthrough --> DirectConnect["Direct Outbound TLS (NO_PROXY)"]
    Inject --> DirectConnect
    DirectConnect --> Figma["Figma MCP Server (mcp.figma.com:443)"]
```

### Acceptance Examples

- AE1. Non-OAuth transparent MCP request
  - **Covers:** R5, R7
  - **Given:** `figma-proxy` holds a valid cached access token.
  - **When:** Antigravity CLI sends an MCP request to `https://mcp.figma.com/mcp` with no `Authorization` header.
  - **Then:** Proxy injects `Authorization: Bearer <token>` and returns the 200 OK MCP payload to Antigravity CLI.

- AE2. Client-provided authorization passthrough
  - **Covers:** R5, R6
  - **Given:** Claude Code sends an MCP request with `Authorization: Bearer claude-custom-token`.
  - **When:** The request passes through `figma-proxy`.
  - **Then:** Upstream request carries `claude-custom-token` unchanged.

- AE3. Non-Figma blind tunneling
  - **Covers:** R4
  - **Given:** `HTTPS_PROXY` is set to `http://127.0.0.1:8888`.
  - **When:** `curl -s https://api.github.com/zen` is executed.
  - **Then:** The connection is tunneled via raw TCP without TLS certificate replacement or inspection.

- AE4. Automatic token refresh
  - **Covers:** R8
  - **Given:** The cached access token is expired, but a valid refresh token exists in `~/.local/state/figma-proxy/tokens.json`.
  - **When:** An unauthenticated request to `https://mcp.figma.com/mcp` is received.
  - **Then:** Proxy refreshes credentials with Figma OAuth endpoint before forwarding the request.

- AE5. On-demand browser login fallback
  - **Covers:** R9
  - **Given:** No tokens are present on disk.
  - **When:** An unauthenticated request is received.
  - **Then:** Proxy opens the system browser to the Figma consent page and finishes exchange before fulfilling the client request.

- AE6. Loopback prevention
  - **Covers:** R10
  - **Given:** `figma-proxy` connects outbound to `mcp.figma.com:443`.
  - **When:** Outbound TCP socket is created.
  - **Then:** Connection bypasses `HTTPS_PROXY` and connects directly to Figma's public IP address.

### Scope Boundaries

- **In scope:**
  - `packages/figma-proxy`: Local proxy daemon and CLI (`figma-proxy login`, `figma-proxy status`).
  - Systemd user service declaration `figma-proxy.service`.
  - User session environment variables (`HTTP_PROXY`, `HTTPS_PROXY`, `NODE_EXTRA_CA_CERTS`) via `environment.d`.
  - Root CA generation, local dynamic cert issuance, and chezmoi integration for system CA store registration.
- **Deferred for later:**
  - Headless OAuth device authorization grant (if/when Figma MCP adds support).
  - Multi-user credential sharing across different Linux user accounts.
- **Outside this product's identity:**
  - Arbitrary URL or general-purpose adblocking MITM inspection.
  - Windows or macOS-specific service daemon wrappers.

### Dependencies / Assumptions

- **Dependencies:**
  - Systemd user session active on the workstation.
  - Default browser available for initial interactive OAuth PKCE approval.
  - Node.js or Bun runtime available for proxy daemon execution.
- **Assumptions:**
  - Figma MCP server maintains OAuth 2.0 PKCE with standard Bearer authorization headers.
  - Clients adhere to standard `HTTP_PROXY` / `HTTPS_PROXY` environment variables for outbound HTTP/HTTPS requests.

### Outstanding Questions

- None blocking planning.

---

## Planning Contract

### Key Technical Decisions

- **KTD1 — Monorepo package architecture in `packages/figma-proxy`.** Create `packages/figma-proxy` managed by the repository's Bun workspace and compiled to a standalone executable `figma-proxy` via `bun build --compile`. Governs U1, U3, U5.
- **KTD2 — Native Node/Bun TLS MITM and blind CONNECT forwarding.** Implement the proxy engine using standard Node.js `http`, `net`, and `tls` modules. For `mcp.figma.com:443`, decrypt TLS using in-memory certificates signed by a local Root CA; for non-Figma destinations, pipe raw sockets via `net.connect` without decryption. Governs U1, U3.
- **KTD3 — Persistent OAuth PKCE client.** Implement RFC 7636 PKCE OAuth flow with dynamic client registration against `https://mcp.figma.com/oauth`. Store session records (`clientInformation`, `tokens`, `codeVerifier`) in `~/.local/state/figma-proxy/tokens.json` restricted to 0600 permissions. Governs U2.
- **KTD4 — Systemd user service integration.** Deploy `dot_config/systemd/user/figma-proxy.service` to start the daemon under `default.target` with restart on failure. Managed by chezmoi lifecycle scripts (`run_after_reload-user-systemd.sh.tmpl`). Governs U4.
- **KTD5 — Declarative environment configuration.** Deploy `dot_config/environment.d/75-figma-proxy.conf` exporting `HTTP_PROXY=http://127.0.0.1:8888`, `HTTPS_PROXY=http://127.0.0.1:8888`, `NO_PROXY=localhost,127.0.0.1`, `NODE_EXTRA_CA_CERTS`, and `SSL_CERT_FILE` pointing to the local Root CA certificate. Governs U4.
- **KTD6 — Local Root CA lifecycle and system trust registration.** Automatically generate `~/.local/share/figma-proxy/ca.crt` and `ca.key` (0600 permissions) on first run if absent. Deploy a chezmoi script installing the certificate to `/etc/pki/ca-trust/source/anchors/figma-proxy-ca.crt` and updating the system store via `update-ca-trust`. Governs U5.

### High-Level Technical Design

```mermaid
flowchart TB
    subgraph Host["Linux Workstation"]
        Env["environment.d (75-figma-proxy.conf)"] -.->|Exports HTTP_PROXY & CA certs| Clients["Harnesses (Antigravity / omp / Claude)"]
        
        subgraph Daemon["figma-proxy (Systemd User Service)"]
            ProxyCore["HTTP CONNECT Listener (:8888)"]
            Router{"Target Host?"}
            CAManager["Local Root CA & Dynamic Cert Issuer"]
            AuthEngine["OAuth PKCE Client & Token Refresher"]
            TokenStore[("~/.local/state/figma-proxy/tokens.json (0600)")]
            
            ProxyCore --> Router
            Router -->|Non-Figma| BlindTunnel["Blind TCP Tunnel"]
            Router -->|mcp.figma.com:443| MITM["TLS Termination & Header Inspection"]
            
            CAManager -->|Dynamic Cert| MITM
            AuthEngine <-->|Read / Write / Refresh| TokenStore
            AuthEngine -->|Inject Bearer| MITM
        end
        
        Clients -->|HTTP CONNECT via Proxy| ProxyCore
    end
    
    BlindTunnel -->|Raw TCP| ExternalWeb["Internet (GitHub, etc.)"]
    MITM -->|Direct HTTPS (NO_PROXY)| FigmaMCP["https://mcp.figma.com/mcp"]
    AuthEngine -->|Browser PKCE Flow| Browser["Default Browser"]
```

### Assumptions

- The workspace Bun version supports `bun build --compile` for the standalone executable target.
- `update-ca-trust` is available on the Fedora workstation to trust user-specified root certificates.
- The default loopback port for the proxy is `8888` (configurable via `FIGMA_PROXY_PORT` environment variable).

---

## Implementation Units

### U1. Core proxy engine, CA generator, and blind tunneling

- **Goal:** Build the HTTP forward proxy server in `packages/figma-proxy` that implements `CONNECT` handling, host-based routing, local Root CA certificate generation, dynamic certificate signing, and blind TCP tunneling.
- **Requirements:** R1, R4, R5, R11
- **Files:**
  - `packages/figma-proxy/package.json`
  - `packages/figma-proxy/tsconfig.json`
  - `packages/figma-proxy/vite.config.ts`
  - `packages/figma-proxy/src/ca.ts`
  - `packages/figma-proxy/src/proxy.ts`
  - `packages/figma-proxy/test/ca.test.ts`
  - `packages/figma-proxy/test/proxy.test.ts`
- **Approach:**
  - In `src/ca.ts`, implement RSA/ECDSA Root CA key generation and X.509 certificate creation using `node:crypto` with 0600 file permissions. Cache dynamic certificates in memory per hostname.
  - In `src/proxy.ts`, create an `http.Server` that listens on `127.0.0.1:8888` and hooks into the `connect` event.
  - For target hosts other than `mcp.figma.com`, establish a raw `net.connect` to the target destination and duplex-pipe data without TLS termination.
  - For `mcp.figma.com:443`, create an internal `tls.createServer` using the dynamic certificate signed by the Root CA, and establish a TLS handshake with the connecting client socket.
- **Test Scenarios:**
  - `ca.test.ts`: Generates CA key and certificate; verifies generated dynamic certificate for `mcp.figma.com` is valid and signed by Root CA.
  - `proxy.test.ts`: Client `CONNECT` to an arbitrary test HTTP server transparently forwards raw TCP bytes.
  - `proxy.test.ts`: Client `CONNECT` to `mcp.figma.com` initiates TLS termination using the Root CA signed certificate.
- **Verification:** `mise -C packages/figma-proxy exec -- vp test` passes.

### U2. OAuth 2.0 PKCE engine and token storage

- **Goal:** Implement the OAuth 2.0 authorization code flow with PKCE, dynamic client registration, token storage in `~/.local/state/figma-proxy/tokens.json`, and automatic token refresh.
- **Requirements:** R8, R9
- **Files:**
  - `packages/figma-proxy/src/oauth.ts`
  - `packages/figma-proxy/src/storage.ts`
  - `packages/figma-proxy/test/oauth.test.ts`
  - `packages/figma-proxy/test/storage.test.ts`
- **Approach:**
  - In `src/storage.ts`, implement atomic read/write of JSON credential payload with `fs.writeFileSync` mode `0o600` under `~/.local/state/figma-proxy/tokens.json`.
  - In `src/oauth.ts`, implement PKCE `code_verifier` and `code_challenge` generation.
  - Implement temporary HTTP callback server on `127.0.0.1:19876/callback` to capture authorization code from browser redirect.
  - Support refreshing access tokens when expired using `grant_type: refresh_token`.
- **Test Scenarios:**
  - `storage.test.ts`: Read/write storage round-trip with secure file permissions assertion.
  - `oauth.test.ts`: PKCE challenge generation; token refresh logic when expiry is reached.
- **Verification:** `mise -C packages/figma-proxy exec -- vp test` passes.

### U3. Request interception, header injection, and CLI commands

- **Goal:** Connect proxy request handling with the OAuth engine to inject Bearer tokens when missing, preserve existing headers, prevent loopback, and provide CLI commands (`login`, `status`, `start`).
- **Requirements:** R3, R6, R7, R9, R10
- **Files:**
  - `packages/figma-proxy/src/cli.ts`
  - `packages/figma-proxy/src/index.ts`
  - `packages/figma-proxy/test/cli.test.ts`
- **Approach:**
  - In the TLS-terminated HTTP request handler, inspect incoming `Authorization` header:
    - If present, forward request as-is to upstream `https://mcp.figma.com` over a direct outbound TLS connection.
    - If missing, retrieve active access token (refreshing or launching browser if none exists), inject `Authorization: Bearer <token>`, and forward.
  - Outbound requests directly create `tls.connect` to real upstream Figma IP address, completely ignoring `HTTP_PROXY`/`HTTPS_PROXY` environment variables to avoid loopback.
  - CLI commands:
    - `figma-proxy start`: Start the proxy server in the foreground.
    - `figma-proxy login`: Trigger browser OAuth flow and save credentials.
    - `figma-proxy status`: Report proxy health, port, and token validity status.
- **Test Scenarios:**
  - `cli.test.ts`: Headerless request receives injected Bearer token.
  - `cli.test.ts`: Request with client `Authorization` header preserves the header unchanged.
  - `cli.test.ts`: Command-line interface routes `status`, `login`, and `start` subcommands.
- **Verification:** `mise -C packages/figma-proxy exec -- vp test` passes.

### U4. Systemd user service and session environment integration

- **Goal:** Deploy the systemd user service unit and user session environment drop-in to automatically start `figma-proxy` and configure environment variables.
- **Requirements:** R1, R2, R13
- **Files:**
  - `dot_config/systemd/user/figma-proxy.service`
  - `dot_config/environment.d/75-figma-proxy.conf`
- **Approach:**
  - In `dot_config/systemd/user/figma-proxy.service`, define a user service running `figma-proxy start` with `Restart=always`, `RestartSec=3`, and wanted by `default.target`.
  - In `dot_config/environment.d/75-figma-proxy.conf`, define:
    ```ini
    HTTP_PROXY=http://127.0.0.1:8888
    HTTPS_PROXY=http://127.0.0.1:8888
    NO_PROXY=localhost,127.0.0.1
    NODE_EXTRA_CA_CERTS=%h/.local/share/figma-proxy/ca.crt
    SSL_CERT_FILE=%h/.local/share/figma-proxy/ca.crt
    ```
- **Test Scenarios:**
  - Verify systemd unit syntax and path referencing `%h/.local/bin/figma-proxy`.
  - Verify environment file exports required variables without syntax errors.
- **Verification:** `chezmoi diff` and manual inspection.

### U5. Chezmoi build script, command manifest, and agents MCP declaration

- **Goal:** Configure chezmoi build script to compile `figma-proxy`, register the binary in commands manifest, register system CA trust, and declare `figma` MCP in `agents.yaml`.
- **Requirements:** R3, R12
- **Files:**
  - `.chezmoidata/commands.yaml`
  - `.chezmoidata/agents.yaml`
  - `.chezmoiscripts/60-build/run_onchange_after_build-figma-proxy.sh.tmpl`
  - `.chezmoiscripts/30-linux/run_onchange_after_install-system-34-figma-ca.sh.tmpl`
- **Approach:**
  - In `.chezmoidata/commands.yaml`, add `figma-proxy` entry under `tools` referencing binary path.
  - In `.chezmoidata/agents.yaml`, add `figma` server under `agents.mcp.servers`:
    ```yaml
    - name: figma
      transport: http
      url: https://mcp.figma.com/mcp
    ```
  - In `.chezmoiscripts/60-build/run_onchange_after_build-figma-proxy.sh.tmpl`, compile `packages/figma-proxy` via `bun build --compile` to `~/.local/bin/figma-proxy`.
  - In `.chezmoiscripts/30-linux/run_onchange_after_install-system-34-figma-ca.sh.tmpl`, copy `ca.crt` to `/etc/pki/ca-trust/source/anchors/` and run `update-ca-trust` if running on Linux.
- **Test Scenarios:**
  - Run `.ci/test-capability-cache.sh` and template rendering tests to ensure syntax and fingerprints pass cleanly.
- **Verification:** `chezmoi diff` shows clean additions without broken fingerprints.

---

## Verification Contract

| Check | Scope | Command / Criteria |
|---|---|---|
| Unit & Integration Tests | `packages/figma-proxy` | `mise -C packages/figma-proxy exec -- vp test` |
| Package Build & Typecheck | `packages/figma-proxy` | `mise -C packages/figma-proxy exec -- vp run build && vp run typecheck` |
| Standalone Binary Build | Workspace | `bun build --compile packages/figma-proxy/src/index.ts --outfile ~/.local/bin/figma-proxy` |
| Template & Manifest Validation | Workspace | `chezmoi diff` renders valid templates with zero parse errors |
| End-to-End Proxy Verification | Host | `curl -x http://127.0.0.1:8888 https://api.github.com/zen` succeeds; `curl -x http://127.0.0.1:8888 https://mcp.figma.com/mcp` connects cleanly |

---

## Definition of Done

- All units U1 through U5 are implemented, tested, and passing.
- `packages/figma-proxy` has full test coverage across CA management, OAuth, and proxy tunneling.
- Systemd user service and environment drop-in files are declared in dotfiles source state.
- Chezmoi scripts and `agents.yaml` MCP configuration compile cleanly without drift.
- All checks in the Verification Contract pass with 0 errors.
