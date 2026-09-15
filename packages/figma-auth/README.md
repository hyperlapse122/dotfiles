# Figma authorization

Run `figma-auth` without arguments to authorize Figma MCP for omp's default
profile. The command opens the browser and accepts the OAuth callback at
`http://127.0.0.1:19876/callback`. It checks state and uses PKCE before saving
credentials in `~/.omp/agent/agent.db`.

Only the Figma credential is replaced after a successful authenticated
connection. Existing database schemas 6 and 7 are accepted. Other providers
and profiles remain unchanged. Cancellation or a failed token exchange leaves
existing credentials intact. Tokens are not printed.

Run `vp test`, `vp run typecheck`, and `vp run build` in this directory.
Tests use isolated databases and simulated OAuth connections. The phase-60
build and command reconciler deploy the executable when deployment is requested.
See [deployment and live checks](../../docs/operations/omp-transition.md).
