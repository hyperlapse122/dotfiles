# omp transition review

Scope: the implementation against `700db6b`, including staged and unstaged
changes in `feature/restore-omp-orca-integration`.

## Coverage

The coordinator reviewed hook delivery, process cleanup, system-only request
rewriting, OAuth state and persistence, managed-path removal, service ordering,
command registration, and related tests and instructions. Review criteria came
from the repository instructions and the correctness, security, reliability,
testing, maintainability, API-contract, and agent-native review guidance.

This is a degraded local review, not an independent review receipt. Orca accepted
three Codex simplification tasks but returned no completion or readable session
output before their 300-second deadlines. After stop, `worker-read` reported
`fallbackReason: session_not_reported`, `sourceExact: false`, and
`contentComplete: false`. All three workers were stopped and released. Their
contexts were `ctx_0c9d48ba2931`, `ctx_1cd198bab766`, and `ctx_5e26b4a99ffd`.
The installed orchestration contract permits current-agent reasoning after
failure of the supported dispatch path. No substitute peer CLI was launched.
Independent code-review and cross-model passes did not run. Claude was excluded
by the user.

## Findings resolved

- **Data preservation:** JSON reserialization rounded `9007199254740993` to
  `9007199254740992` and changed `1e400` to `null` outside the system prompt.
  The proxy now replaces only selected string tokens. A regression test failed
  before the change and passed afterward, preserving all other raw bytes.
- **Cancellation:** a client disconnect before response headers did not cancel
  upstream work. The HTTP bridge now propagates that disconnect. A real local
  HTTP test verifies the upstream abort signal.
- **Hook cleanup:** a child that ignored SIGTERM could survive the deadline.
  The extension now escalates process-group termination and bounds output.
  It removes stale owned context on hook failure.
- **Verification loss:** restored the hook suite's timeout, process-group,
  declaration, trust-record, and stdin cases that the initial implementation
  had removed.
- **Deployment:** service activation now follows build and command phases.
  It retries an absent Linux session bus and restarts on binary or unit changes.
  Unsafe staging destinations fail without replacing the existing executable.
- **Removal evidence:** applied the rendered removal list twice in an isolated
  home. Managed command links and plugin files disappear; authentication,
  history, the omp database, and shared archives retain their sentinels.
- **Documentation:** added package usage and verification instructions and
  corrected the managed-harness documentation.

No actionable finding from this local review remains unresolved.

## Verification and limits

All 544 package tests, workspace type checks, builds, formatting and lint pass.
Affected shell gates cover hook integration, instructions, trust, plugins,
settings, MCP, commands, release checksums, build staging, removal, and Linux
and macOS service activation. Tests use isolated homes, databases, and services.

Browser flow: Figma OAuth consent is **Skip** because it requires a live account
and operator interaction. Callback behavior is covered by HTTP tests. No other
browser page is changed. No browser driver or real authentication session ran.

Deployment, actual Orca/omp dispatch, upstream generation, and live Figma access
remain unrun under the plan's R15 boundary. The current session's injected rules
still prohibit omp dispatch. Source changes do not change that active contract.
See the [deployment checks](../operations/omp-transition.md).

The historical workspace-trust learning informed additive state preservation.
The SELinux agent-config learning is explicitly superseded and supplies no
current deployment requirement.
