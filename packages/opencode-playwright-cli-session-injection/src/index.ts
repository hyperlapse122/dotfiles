import type { Plugin, PluginInput } from "@opencode-ai/plugin";
import { createHash } from "node:crypto";

const envVarName = "PLAYWRIGHT_CLI_SESSION";

export const PlaywrightCliSessionInjectionPlugin: Plugin = async (_input: PluginInput) => {
  return {
    "shell.env": async (input, output) => {
      if (!input.cwd) return;

      const hash = createHash("sha1").update(input.cwd).digest("hex");
      const sessionName = `opencode-${hash.substring(0, 8)}`;
      output.env[envVarName] = sessionName;
    },
  };
};
