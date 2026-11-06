/** Keep the native effective catalog equal to the committed Synthetic lock. */
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { getBuiltinProviders } from "@earendil-works/pi-ai/providers/all";

export default function (pi) {
  const directory = dirname(fileURLToPath(import.meta.url));
  const document = JSON.parse(readFileSync(join(directory, "dotfiles-model-lock.json"), "utf8"));
  const catalog = document.syntheticModelLocks;
  if (!catalog || catalog.provider !== "synthetic" ||
      catalog.api !== "openai-completions" ||
      catalog.baseUrl !== "https://api.synthetic.new/openai/v1" ||
      !Array.isArray(catalog.models) || !catalog.models.length) {
    throw new Error("The managed Synthetic model lock is unavailable.");
  }
  const ids = new Set(catalog.models.map(model => model.id));
  if (ids.size !== catalog.models.length) throw new Error("Duplicate locked Synthetic model.");
  const configured = JSON.parse(readFileSync(join(directory, "models.json"), "utf8"));
  const known = new Set([...getBuiltinProviders(), ...Object.keys(configured.providers ?? {})]);
  function register(registry) {
    if (registry) for (const model of registry.getAll()) known.add(model.provider);
    for (const provider of known) {
      if (provider !== "synthetic") pi.registerProvider(provider, { models: [] });
    }
    pi.registerProvider("synthetic", {
      baseUrl: catalog.baseUrl, api: catalog.api, models: catalog.models,
      refreshModels: async () => catalog.models,
    });
  }
  register();
  function stop(context, message) {
    process.stderr.write(message + "\n");
    process.exitCode = 1;
    context.shutdown();
  }
  pi.on("session_start", (_event, context) => {
    const branch = context.sessionManager.getBranch();
    const selected = [...branch].reverse().find(entry => entry.type === "model_change");
    // Native Pi otherwise resumes a removed selection using its default model.
    if (branch.some(entry => entry.type === "message") && selected &&
        (selected.provider !== "synthetic" || !ids.has(selected.modelId))) {
      stop(context, "The saved model is unavailable in the managed Synthetic lock.");
    }
  });
  // Other preserved extensions can register providers during session_start.
  // Resource discovery follows that event, including the native /reload path.
  pi.on("resources_discover", async (_event, context) => {
    register(context.modelRegistry);
    await context.modelRegistry.refresh();
    const models = context.modelRegistry.getAll();
    if (models.length !== ids.size || models.some(model => model.provider !== "synthetic" || !ids.has(model.id))) {
      stop(context, "The effective model catalog violates the managed Synthetic policy.");
    }
    if (context.model && (context.model.provider !== "synthetic" || !ids.has(context.model.id))) {
      stop(context, "The selected model is not in the managed Synthetic lock.");
    }
  });
}
