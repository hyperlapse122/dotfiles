# omp transition

This change replaces managed Antigravity CLI with omp. The Google Antigravity
model provider remains in use through a local sidecar.

## Deployment

Apply only after the operator requests deployment. Apply from this checkout's
source root. The build phase stages the hook, omp extension, sidecar, and
`figma-auth`. Command reconciliation installs the executables before the
phase-70 service activation.

Linux uses the `antigravity-sidecar.service` user unit. macOS uses the
`app.dotfiles.antigravity-sidecar` LaunchAgent. A changed binary or service
definition triggers a restart. An unchanged running service stays running.
Linux activation retries on a later apply if the user session bus is absent.

The proxy binds to `127.0.0.1:45123`. Keep omp's
`providers.antigravityEndpoint` set to `auto` so its provider `baseUrl` is used.
Only `request.systemInstruction.parts[].text` is transformed. The proxy does
not fall back to direct upstream access on failure.

## Preserved state

The removal list names managed Antigravity commands, instruction files, MCP
configuration, and plugin bundles. Public executable links are removed only
when their targets identify the retired managed command. Authentication,
conversation history, other executables, and shared plugin archives remain.

Run `figma-auth` without arguments when Figma authorization is needed. It
replaces only the Figma OAuth record after a successful token exchange and
accepts existing omp database schemas 6 and 7. Do not delete `agent.db` or use
the old omp decommission procedure for this transition.

## Checks after deployment

1. Confirm the sidecar user service is running and reports no port conflict.
2. Start fresh omp lead and worker sessions through Orca. Confirm each receives
   its role's instructions before the first model call.
3. Complete an Orca worker task, then resume the session. Confirm completion
   delivery and that the instruction block does not accumulate.
4. Run an Orca Git action. Confirm omp handles it with the existing model
   policy. The ordinary TUI default remains Claude.
5. Check streaming, a tool call, and cancellation through the sidecar. A stopped
   proxy or upstream quota error must be visible as a failure.
6. Run `figma-auth`, verify Figma access in omp, and confirm cancellation leaves
   existing credentials intact.

Repository tests use isolated stores and fake services. These live checks have
not been performed by the source-only implementation run.
