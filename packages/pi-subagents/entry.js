import { fileURLToPath } from "node:url";

export default async function (pi) {
  const { T3_PI_RUNTIME_MODE: mode, T3_PI_MCP_EXTENSION_PATH: extension } = process.env;
  const args = process.argv.slice(2);
  const rpc = args.some((arg, index) => arg === "--mode" && args[index + 1] === "rpc");
  // T3 discovery runs in RPC mode without a runtime mode or an MCP extension path.
  if ((rpc || mode !== undefined || extension !== undefined) && !(extension && mode === "full-access")) return;

  const { default: register } = await import("./bundle/index.js");
  await register(pi);
  pi.on("resources_discover", () => ({
    skillPaths: args.includes("--no-skills") || args.includes("-ns")
      ? [] : [fileURLToPath(new URL("./skills", import.meta.url))],
    promptPaths: args.includes("--no-prompt-templates") || args.includes("-np")
      ? [] : [fileURLToPath(new URL("./prompts", import.meta.url))],
  }));
}
