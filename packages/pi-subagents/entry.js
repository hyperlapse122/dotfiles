import { fileURLToPath } from "node:url";

export default async function (pi) {
  const args = process.argv.slice(2);

  const { default: register } = await import("./bundle/index.js");
  await register(pi);
  pi.on("resources_discover", () => ({
    skillPaths: args.includes("--no-skills") || args.includes("-ns")
      ? [] : [fileURLToPath(new URL("./skills", import.meta.url))],
    promptPaths: args.includes("--no-prompt-templates") || args.includes("-np")
      ? [] : [fileURLToPath(new URL("./prompts", import.meta.url))],
  }));
}
