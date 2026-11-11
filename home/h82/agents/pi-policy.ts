import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

export default function (pi) {
  const directory = dirname(fileURLToPath(import.meta.url));
  const document = JSON.parse(readFileSync(join(directory, "model-lock.json"), "utf8"));
  const catalog = document.syntheticModelLocks;
  if (!catalog || catalog.provider !== "synthetic" ||
      catalog.api !== "openai-completions" ||
      catalog.baseUrl !== "https://api.synthetic.new/openai/v1" ||
      !Array.isArray(catalog.models) || !catalog.models.length) {
    throw new Error("The managed Synthetic model lock is unavailable.");
  }
  const ids = new Set(catalog.models.map(model => model.id));
  if (ids.size !== catalog.models.length) throw new Error("Duplicate locked Synthetic model.");
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
  // The packaged runtime enforces the catalog before project extensions load.
  pi.on("resources_discover", async (_event, context) => {
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
