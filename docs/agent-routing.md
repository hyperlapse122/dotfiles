# Agent routing

The ordinary user instruction files share scope and verification, language, and action triggers for the installed task guide. Delegation uses CE and harness defaults or the user’s explicit selection; dotfiles does not assign child models or efforts, check quota before delegation, or substitute providers. Interactive session defaults and standalone usage tools remain separate. Claude Code, Codex, Pi, and OpenCode each receive their own render; OpenCode's is the shared base render with no branch of its own.

The shared instructions identify `agent-check` as the project's check when the project defines it. The Home Manager helper runs that task for manual checks, Git hooks, and CI. [Project setup](agent-check.md)

The shared instructions call for one `decide` judgment during CI triage when the failure evidence leaves multiple plausible read-only checks and the answer would change which check runs first. The agent verifies the suggested lead and continues the investigation if the tool yields no usable answer. [Decide MCP tool](decide.md#use-the-mcp-tool)

The language rules make Korean the default conversation language and English the default for artifacts such as documents, code comments, and commit messages. A language named in the conversation or the project's instructions, or the language of existing content, takes precedence for artifacts. Claude Code's render leaves out the conversation rule because its `language` setting already sets the conversation language; it keeps the artifact rule.

Shared guidance is exposed through domain entries: `web-lenses`, `engineering-lenses`, `design-lenses`, `mobile-lenses`, and `writing-lenses`. `project-skills` discovers version-matched guidance supplied by installed project dependencies. Open the entry for the work and follow its references; grouped guides do not each occupy a user-scope discovery entry.

Shared Home Manager configuration installs [acpx](../packages/acpx.nix) on both NixOS and macOS. The package honors user-level `~/.acpx/config.json` and skips project-local `.acpxrc.json` when resolving configuration.

## Project skills for shadcn and Figma

Project-owned skills remain in their project's scope. For an Intent-compatible dependency, use `project-skills` to find guidance visible in the working project; absent or incompatible guidance falls back to a compatible installed reference or version-matched official documentation. Do not install dependencies or create project skills or instructions as part of discovery.

The following historical checks used synthetic project-owned skills and do not imply that this repository manages skills in other checkouts.

Disposable Git projects on macOS and NixOS confirmed the following with synthetic `shadcn` and `implement-design` skills.

| Harness | Project discovery |
| --- | --- |
| Codex 0.171.0 | Found both from a nested directory in a trusted checkout. |
| Pi 1.5.2 | Found both from a nested directory with `--approve`. With `--no-approve`, Pi skipped them. |
| OpenCode 2.3.2 | Found both from a nested directory. |
| Claude Code 2.1.329 | Found both through `.claude/skills/` directory links at the project root. |

## OpenCode review recipients

The shared `CROSS_MODEL_PEERS` list includes `claude`, `codex`, and `opencode` where those harnesses are installed. This makes the OpenCode route selectable in standalone and T3 sessions without changing the default peer in other harnesses. Before either CE review skill uses OpenCode, it must select an exact `provider/model` and disclose the recipients. If the allowlist is set, the OpenCode token authorizes the route, not the downstream provider. Direct Anthropic and OpenAI calls also need `claude` and `codex`, respectively. An unknown or unauthorized route is unavailable.

## Decide for subagent roles

Once a workflow has decided to delegate, the parent uses the role selector on the existing launch route. A required role or a sole eligible role goes directly to the launcher. With two or more eligible roles, the parent asks `judge` once using `choice` and passes the selected role to the launcher. The existing selection path handles sessions without a role choice and any unavailable or unusable judgment.

The parent checks role purpose, conditions, tools, and compatibility with required launch settings before asking. Claude Code starts with the pinned catalog at `~/.local/share/nix-config/claude-code-agents.json` and applies the session's effective definitions. The request contains a short task summary and eligible role descriptions that the configured backend may receive. It includes an `insufficient_evidence` option. [Pinned catalog](../packages/claude-code-agents.json) · [Decide backends](decide.md#backends-and-models)

A Claude Code `fork` uses the parent's model and full conversation. It qualifies only when the workflow permits those effective settings. [Claude Code fork behavior](https://code.claude.com/docs/en/sub-agents#how-forks-differ-from-other-subagents)

T3 0.1.9's `delegate_task` applies its `role` as guidance in the child prompt. Provider, model, effort, and tool access come from the launch route. A native launch inside T3 uses the harness's own selector when available. [T3 child prompt construction](https://github.com/pingdotgg/t3code/blob/v0.1.9/apps/server/src/mcp/delegatedTaskModes.ts#L90-L94)

### Session checks

These checks used the pinned harnesses, staged policy, synthetic Markdown fixtures, and local MLX judgments on macOS. Role availability depends on the active launch tool and session permissions.

| Harness | Standalone | Managed T3 Code |
| --- | --- | --- |
| Claude Code | The parent sent `Explore` and `general-purpose` for a native file lookup. `judge` chose `Explore`, and the launch passed `subagent_type: Explore`. | The native planning task sent `Plan` and `general-purpose`. `judge` chose `Plan`, and the launch passed `subagent_type: Plan`. |
| Codex | The tested `spawn_agent` exposed no role selector. It launched through its default path without judgment. | The tested native tool exposed no role selector. On a task routed to `delegate_task`, `judge` chose `research` from `general` and `research`, and the launch passed `role: research`. |
| Pi | The managed `pi-subagents` extension offers named agents in terminal Pi and full-access T3 Pi. | On a task routed to `delegate_task`, `judge` chose `research` from `general` and `research`, and the launch passed `role: research`. |

Each recorded judgment included `insufficient_evidence`. Claude also launched a required `Explore` role and a sole eligible `Explore` role without judgment. When the session denied the MCP call, Claude used its default selection path and completed the task.

## T3 task guidance

The authoritative [T3 guide](../home/h82/agents/instructions/t3-guide.md) covers T3 delegation, PR and MR watching, multi-PR threads, and visual options. Home Manager installs it at `~/.local/share/nix-config/agent-instructions/t3-guide.md` for use outside this checkout. The [task guide](../home/h82/agents/instructions/task-guide.md) covers personal procedures and is installed beside it.

## Native T3 launches

`home/h82/t3code.nix` merges the captured server and client preferences into writable T3 settings. New threads use Codex `gpt-6.2-astra` at `ultra` effort, with Claude Opus 5.5 as fallback. Threads start with full access in a worktree. Inactive worktree cleanup uses five days. The interface uses Pretendard Variable; code and terminals use Jetendard. Baseline-only settings remain declared unless the overlay replaces them, and unrelated user settings survive application.

T3 Code uses Claude Code `claude-haiku-5-5` at its native effort as its shared text generation model. It asks for Conventional Commit-style titles when generating or regenerating a thread title. Commit messages, PR text, branch names, and voice transcript cleanup use the shared model unless their settings select another one. Review guides follow the source control writer selection when one is set and otherwise use the shared model, so no review guide selection is declared and activation removes a stored one. This selection does not turn on review guides.

Claude, Codex, Pi, and OpenCode share their normal homes, credentials, plugins, and baseline instruction files with CLI sessions. Activation renders only the template's T3 branch into private files under `~/.t3/userdata/instructions/`. The launch composer passes Claude `--append-system-prompt-file`, Codex `-c developer_instructions=...`, and Pi `--append-system-prompt`. OpenCode has no such option, and a global `instructions` entry would reach sessions outside T3 Code, so the OpenCode instance lists its file in `OPENCODE_CONFIG_CONTENT` in its environment, which T3 Code hands to the server it starts. OpenCode reads the baseline from `~/.config/opencode/AGENTS.md`. Existing append options and Codex developer instructions are composed with the addition. Claude append-file paths must be absolute. Reapply after changing those files or native Codex developer instructions; their contents are captured during application. The private `dotfiles-launch-state.json` tracks contributions so repeated application preserves unrelated argument and environment edits. CLI launches receive the baseline only.

Claude uses idle compaction before the cache expires. The T3 provider uses Claude's default subagent depth unless its environment includes a user-specified value. The standalone CLI retains its configured cap. Activation retires dotfiles' old Claude and existing-mode Codex launch controls using their recorded contributions. Pi uses the managed package in the shared user profile and hides its `default` model while preserving the user's other hidden choices.

Activation removes the retired Grok Build launch configuration and disables the default Grok instance. T3 Code 0.1.9 can otherwise restore the instance from session history.

Activation disables the former managed Antigravity ACP provider and removes its launch override on upgrade. Saved credentials and conversations stay on disk.

T3 cannot enforce a read-only delegate. The T3 guide describes the owner's exception for CE cross-model review and its disclosure requirements.

Close T3 before applying and relaunch it afterward. Repository checks execute the rendered activation and inspect launch arguments and instruction files. These checks establish activation output; they do not establish signed-in provider behavior, model compliance, or the T3 desktop experience on either host.

## Pi tools and project trust

The Pi package builds pinned upstream source with no repository patch. Its fixed-hash source fetch lets Nix read package metadata and dependency locks without building a derivation during evaluation. `models.json` declares the committed Synthetic catalog and, for OpenAI and Anthropic, the models of the committed lists (`home/h82/agents/openai-models.json` and `home/h82/agents/anthropic-models.json`) that Pi's compiled catalog lacks, computed at build time from the catalog the Pi build pins and checked against the packaged runtime by the Pi runtime test, because a declared row replaces a catalog model and drops its compat, thinking-level, and cache settings. `pi-state` sets `enabledModels` to the visible Synthetic models and every listed OpenAI and Anthropic model, so startup selection and cycling follow the lists while `/model` still shows Pi's whole catalog. `scripts/provider-models-watch` rebuilds each list every 30 minutes from the provider's list API and models.dev, keeping ids that fully match `gpt-(?:[0-9.]+)-(?:\w+)` with version 6.1 or higher (OpenAI) or `claude-(?:\w+)-(?:[0-9\-.]+)` (Anthropic). OpenCode declares the same rows under `providers.openai.models` and `providers.anthropic.models`. The lists declare models and do not enforce them: Pi refreshes its catalog from pi.dev, and a project setting, extension, or `models.json` can add providers or models or override an endpoint. Trusted extensions still execute arbitrary JavaScript as the user.

The shared `~/.pi/agent/` contains the repository-owned `question`, `web_search`, and `web_fetch` extensions. Questions use native select and input dialogs, with distinct cancellation, empty-answer, and unavailable-UI results. Web tools use Exa and return bounded source content with URLs for citations. Page content is untrusted input.

The wrapper clears inherited `EXA_API_KEY` and exports only `DOTFILES_PI_EXA_KEY_FILE`, pointing to the existing published `exa_api_key`. The extension reads the file on each call. It does not copy the key into Pi settings, authentication, arguments, or subprocess environments. A missing key disables web calls without preventing Pi or questions from working. Trusted extensions can still read files accessible to the user.

T3's launch composer adds `--approve` for Pi and preserves user-added arguments through its ownership ledger. Approval applies to that run and does not update remembered project decisions. Terminal Pi uses native per-project trust prompts, preserving previous decisions. T3 project resources and web queries carry the code-execution and disclosure risks accepted in issue [#139](https://github.com/hyperlapse122/dotfiles/issues/139).

Home Manager registers the pinned `pi-subagents` package in the shared Pi home. Start a fresh session after applying the configuration. Its commands and tools are available in terminal Pi and in T3 Pi sessions that report full access. T3's discovery process and restricted sessions do not load the plugin. This is separate from T3's `delegate_task`: T3 does not supervise plugin-managed runs, including background runs and external runners. The plugin keeps its upstream child trust behavior: a child can reuse its parent's project trust in another directory. Use a child directory only if you trust its project configuration.

The managed package does not disable extensions installed outside Pi's package list. If you previously ran `npx pi-subagents`, move that copy out of `~/.pi/agent/extensions/` before relying on the managed package's T3 restriction. Activation leaves manually installed files untouched.

Repository checks exercise materialized files for both host kinds, packaged CLI and SDK model paths, native RPC dialogs, subprocess environments, and project skill discovery. These checks use fake credentials. They do not establish the live T3 dialog experience, signed-in Exa calls, or either host's installed generation; those require post-switch evidence from the owner.
