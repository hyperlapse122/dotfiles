#!/usr/bin/env bun
import { readFile } from "node:fs/promises";
import {
  PLUGIN_CONTRACT,
  reconcilePlugin,
  reconcileSettings,
  SETTINGS_CONTRACT,
} from "./reconcile.js";

const [command, ...args] = process.argv.slice(2);

if (command === "contracts") {
  process.stdout.write(
    JSON.stringify({ settings: SETTINGS_CONTRACT, plugin: PLUGIN_CONTRACT }) + "\n",
  );
} else if (command === "settings") {
  const [home, file, declaredPath] = args;
  if (!home || (file !== "config.toml" && file !== "tui.toml") || !declaredPath) usage();
  const declared = JSON.parse(await readFile(declaredPath, "utf8")) as Record<string, unknown>;
  await reconcileSettings(home, file, declared);
} else if (command === "plugin") {
  const [home, source, release] = args;
  if (!home || !source || !release) usage();
  await reconcilePlugin(home, source, release);
} else {
  usage();
}

function usage(): never {
  process.stderr.write("Usage: kimi-reconcile <contracts|settings|plugin> ...\n");
  process.exit(2);
}
