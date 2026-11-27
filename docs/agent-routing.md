# Agent routing

The shared user-scope template currently contains only comments and a common-baseline branch skeleton. Normal activation produces byte-empty native instruction files for Claude Code, Pi, OpenCode, and omp (`~/.omp/agent/AGENTS.md`). Project instructions, independent harness settings, and shared skills remain active; Claude Code's own settings still select Korean conversation.

Delegation uses the role, model, and reasoning effort selected by CE or the harness unless the user specifies them.

Shared guidance is exposed through domain entries: `web-lenses`, `engineering-lenses`, `design-lenses`, `mobile-lenses`, `writing-lenses`, `service-lenses`, `platform-lenses`, and `toolchain-lenses`. `project-skills` discovers version-matched guidance supplied by installed project dependencies. Open the entry for the work and follow its references; grouped guides do not each occupy a user-scope discovery entry.

Shared Home Manager configuration installs [acpx](../packages/acpx.nix) on both NixOS and macOS. The package honors user-level `~/.acpx/config.json` and skips project-local `.acpxrc.json` when resolving configuration.

## Native edit and commit guards

Home Manager configures the `preShell` and `freezeTests` guards for Claude Code, Pi, and OpenCode. The first catches common attempts to skip Git commit hooks. To protect test files from native edits, create `.agents/freeze-tests` at the Git root. Protection covers test and spec directories, conventional test filenames, and both paths of a rename. Set `my.agentHooks.<harness>.enable` to false to disable both guards, or configure them individually.

## Checking shared skill discovery

On Linux, fresh homes with the same harness binaries listed all 17 shared entries before grouping and all nine afterwards, once each. The counts exclude built-in and plugin skills. These checks used a non-project working directory and sent no model prompt.

| Harness | How to read the session's skill list |
| --- | --- |
| Claude Code 2.1.330 | Inspect the stream-JSON initialization response with user settings enabled. Bare mode skips user skills. |
| Pi 1.6.0 | Inspect the skill commands returned by the offline RPC `get_commands` request. |
| OpenCode 2.3.2 | Start a loopback server with temporary local authentication. Read `/api/skill` for the working directory, passing `location[directory]`. Use a bounded wait for the expected entries. The API can return HTTP 200 with only built-in entries while it is still loading directory skills. |

Home Manager checks cover the managed skill roots and instruction delivery. The counts above come from standalone processes.

## Project skills for shadcn and Figma

Project-owned skills remain in their project's scope. For an Intent-compatible dependency, use `project-skills` to find guidance visible in the working project; absent or incompatible guidance falls back to a compatible installed reference or version-matched official documentation. Do not install dependencies or create project skills or instructions as part of discovery.

The following historical checks used synthetic project-owned skills and do not imply that this repository manages skills in other checkouts.

Disposable Git projects on macOS and NixOS confirmed the following with synthetic `shadcn` and `implement-design` skills.

| Harness | Project discovery |
| --- | --- |
| Pi 1.5.2 | Found both from a nested directory with `--approve`. With `--no-approve`, Pi skipped them. |
| OpenCode 2.3.2 | Found both from a nested directory. |
| Claude Code 2.1.329 | Found both through `.claude/skills/` directory links at the project root. |

## CE review peers

The shared `CROSS_MODEL_PEERS` list includes `claude` and `opencode` where those harnesses are installed. CE uses this list when selecting a peer for cross-model review.

## Pi tools and project trust

The Pi package builds pinned upstream source with no repository patch. Its fixed-hash source fetch lets Nix read package metadata and dependency locks without building a derivation during evaluation. `models.json` declares the committed Synthetic catalog and, for Anthropic, the models of the committed list (`home/h82/agents/anthropic-models.json`) that Pi's compiled catalog lacks, computed at build time from the catalog the Pi build pins and checked against the packaged runtime by the Pi runtime test, because a declared row replaces a catalog model and drops its compat, thinking-level, and cache settings. `pi-state` sets `enabledModels` to the visible Synthetic models and every listed Anthropic model, so startup selection and cycling follow the lists while `/model` still shows Pi's whole catalog. `scripts/provider-models-watch` rebuilds the Anthropic list every 30 minutes from the provider's list API and models.dev, keeping ids that fully match `claude-(?:\w+)-(?:[0-9\-.]+)`. OpenCode declares the same rows under `providers.anthropic.models`. The lists declare models and do not enforce them: Pi refreshes its catalog from pi.dev, and a project setting, extension, or `models.json` can add providers or models or override an endpoint. Trusted extensions still execute arbitrary JavaScript as the user.

The shared `~/.pi/agent/` contains the repository-owned `question`, `web_search`, and `web_fetch` extensions. Questions use native select and input dialogs, with distinct cancellation, empty-answer, and unavailable-UI results. Web tools use Exa and return bounded source content with URLs for citations. Page content is untrusted input.

The wrapper clears inherited `EXA_API_KEY` and exports only `DOTFILES_PI_EXA_KEY_FILE`, pointing to the existing published `exa_api_key`. The extension reads the file on each call. It does not copy the key into Pi settings, authentication, arguments, or subprocess environments. A missing key disables web calls without preventing Pi or questions from working. Trusted extensions can still read files accessible to the user.

Pi uses native per-project trust prompts, preserving previous decisions. Pi project resources and web queries carry the code-execution and disclosure risks of the projects and pages they read.

Home Manager registers the pinned `pi-subagents` package in the shared Pi home. Start a fresh session after applying the configuration. Its commands and tools are available in terminal Pi. The plugin keeps its upstream child trust behavior: a child can reuse its parent's project trust in another directory. Use a child directory only if you trust its project configuration.

The managed package does not disable extensions installed outside Pi's package list. If you previously ran `npx pi-subagents`, move that copy out of `~/.pi/agent/extensions/` before relying on the managed package. Activation leaves manually installed files untouched.

Repository checks exercise materialized files for both host kinds, packaged CLI and SDK model paths, native RPC dialogs, subprocess environments, and project skill discovery. These checks use fake credentials. They do not establish signed-in Exa calls or either host's installed generation; those require post-switch evidence from the owner.
