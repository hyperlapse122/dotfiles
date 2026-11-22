# Shared skill discovery and selection

## Codex model-visible descriptions

On macOS and NixOS, the actual 0.169.0 and 0.171.0 binaries sent a first-turn Responses API request to a loopback recorder. Disposable homes linked each host's installed user skill directories and loaded bundled skills plus the pinned Compound Engineering plugin. The fixture used `gpt-6.2-sol` and did not attach other desktop plugins or send an inference request to a provider. The installed configuration on each host left `skills.max_context_tokens` and `model_context_window` unset. The source for [0.169.0](https://github.com/openai/codex/blob/rust-v0.169.0/codex-rs/ext/skills/src/render.rs) and [0.171.0](https://github.com/openai/codex/blob/rust-v0.171.0/codex-rs/ext/skills/src/render.rs) derives the default budget from 2% of the model context window and caps explicit overrides at 10,000 tokens.

| Host | Codex | Fixture | Rows at default | Descriptions shortened relative to 10,000 tokens | Budget warning at default |
| --- | --- | --- | ---: | ---: | --- |
| macOS | 0.169.0 | Baseline | 71 | 20 | No |
| NixOS | 0.169.0 | Baseline | 59 | 4 | No |
| macOS | 0.171.0 | Baseline | 71 | 0 | No |
| NixOS | 0.171.0 | Baseline | 59 | 0 | No |
| macOS | 0.171.0 | Router candidate | 65 | 0 | No |
| NixOS | 0.171.0 | Router candidate | 53 | 0 | No |

Both versions honored the override. At 128 tokens, macOS sent five rows with no descriptions and NixOS sent seven with no descriptions. All runs at this budget emitted an omission warning. At 1,200 tokens the macOS 0.171.0 baseline warned, kept 70 of 71 rows and removed their descriptions. The macOS candidate kept all 65 rows with abbreviated descriptions and emitted no warning. A missing warning alone does not establish that descriptions were complete.

Both managed-version candidate requests included the full 322-character router description. At 10,000 tokens the seven previous mobile descriptions took 2,502 characters before row names and locators. The 0.169.0 Linux baseline shortened `expo-ui`, `modern-web-guidance`, `playwright-best-practices`, and `ux-writing` at its default budget. The 0.169.0 macOS baseline shortened those and 16 others. The reported runs inspect the outbound model input and startup warning events. The previous `skills/list` check is separate evidence.

## Project discovery

Synthetic shadcn and Figma fixtures contained descriptions with distinct markers. Both hosts produced the same result.

| Harness | Observation |
| --- | --- |
| Codex 0.171.0 | First-turn model input from a nested directory in a trusted Git checkout carried both project descriptions. |
| Pi 1.5.2 | Native RPC `get_commands` reported both with project scope from the nested directory under `--approve`, and neither under `--no-approve`. |
| OpenCode 2.3.2 | The initialized private server's `GET /api/skill` returned both project IDs and paths from the nested directory. |
| Claude Code 2.1.329 | Stream initialization and the captured Messages API request omitted both with `.agents/skills` alone. Both appeared after installing directory links in the project's `.claude/skills`. |

The fixtures used no provider credentials. The Figma fixture was named `implement-design` after the issue. The docs show the current upstream name, `figma-design-to-code`.

## Mobile skill selection

Two independent Codex runs classified the same 16 requests using the original catalog and the candidate catalog. Each selected a mobile skill for all eight Expo or React Native tasks and none of the eight near misses. The candidate therefore retains the selection behavior on this sample with one entry in place of seven.
