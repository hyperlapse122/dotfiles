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
  function lockedIds(lock, provider) {
    if (!lock || lock.provider !== provider || !Array.isArray(lock.models) || !lock.models.length) {
      throw new Error(`The managed ${provider} model lock is unavailable.`);
    }
    const ids = new Set(lock.models.map(model => model.id));
    if (ids.size !== lock.models.length) throw new Error(`Duplicate locked ${provider} model.`);
    return ids;
  }
  const locks = new Map([
    ["synthetic", lockedIds(catalog, "synthetic")],
    ["openai", lockedIds(document.openaiModelLocks, "openai")],
    ["anthropic", lockedIds(document.anthropicModelLocks, "anthropic")],
  ]);
  const synthetic = locks.get("synthetic");
  const allowed = (provider, id) => locks.get(provider)?.has(id) === true;
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
        !allowed(selected.provider, selected.modelId)) {
      stop(context, "The saved model is unavailable in the managed model lock.");
    }
  });
  // The packaged runtime enforces the catalog before project extensions load.
  // A built-in provider's lock can name a model Pi's catalog does not define.
  pi.on("resources_discover", async (_event, context) => {
    await context.modelRegistry.refresh();
    const models = context.modelRegistry.getAll();
    const syntheticModels = models.filter(model => model.provider === "synthetic");
    if (syntheticModels.length !== synthetic.size ||
        models.some(model => !allowed(model.provider, model.id))) {
      stop(context, "The effective model catalog violates the managed model lock.");
    }
    if (context.model && !allowed(context.model.provider, context.model.id)) {
      stop(context, "The selected model is not in the managed model lock.");
    }
  });
}
