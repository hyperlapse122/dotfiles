#!/usr/bin/env bun
import { readFile } from "node:fs/promises";
import { reconcileSettings, SETTINGS_CONTRACT } from "./reconcile.js";

const [command, ...args] = process.argv.slice(2);

try {
  if (command === "contracts") {
    process.stdout.write(JSON.stringify({ settings: SETTINGS_CONTRACT }) + "\n");
  } else if (command === "settings") {
    const [home, file, declaredPath] = args;
    if (!home || (file !== "config.toml" && file !== "tui.toml") || !declaredPath) usage();
    const declared = JSON.parse(await readFile(declaredPath, "utf8")) as Record<string, unknown>;
    await reconcileSettings(home, file, declared);
  } else {
    usage();
  }
} catch (error) {
  // The reconciler's failures are operator-actionable (a foreign symlink in the
  // managed target tree, drifted state) — report the reason, not a stack trace
  // through the compiled single-file bundle.
  process.stderr.write(
    `kimi-reconcile: ${error instanceof Error ? error.message : String(error)}\n`,
  );
  process.exit(1);
}

function usage(): never {
  process.stderr.write("Usage: kimi-reconcile <contracts|settings> ...\n");
  process.exit(2);
}
