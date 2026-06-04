import type { Plugin, PluginInput } from "@opencode-ai/plugin";
import slugify from "slugify";

const envVarName = "PLAYWRIGHT_CLI_SESSION";

export const PlaywrightCliSessionInjectionPlugin: Plugin = async (_input: PluginInput) => {
  return {
    "shell.env": async (input, output) => {
      if (!input.cwd) return;

      output.env[envVarName] = `opencode-at-${slugify(input.cwd, {
        lower: true,
        strict: true,
        replacement: "-",
      })}`;
    },
  };
};
