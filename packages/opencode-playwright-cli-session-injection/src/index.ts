import type { Plugin, PluginInput } from "@opencode-ai/plugin";
import slugify from "slugify";
import {sep} from "node:path";

const envVarName = "PLAYWRIGHT_CLI_SESSION";

export const PlaywrightCliSessionInjectionPlugin: Plugin = async (_input: PluginInput) => {
  return {
    "shell.env": async (input, output) => {
      if (!input.cwd) return;

      const normalizedCwd = input.cwd.split(sep).join("-");
      const slugifiedCwd = slugify(normalizedCwd, {
        lower: true,
        strict: true,
        replacement: "-",
      })
      output.env[envVarName] = `opencode-at-${slugifiedCwd}`;
    },
  };
};
