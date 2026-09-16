#!/usr/bin/env bun
import { readFile } from "node:fs/promises";
import { reconcileSettings, SETTINGS_CONTRACT } from "./reconcile.js";
import { reconcileTrust } from "./trust.js";
import {
  extractServers,
  parseInventoryContent,
  synthesizeMcpManifest,
  validateInventory,
  type HarnessKind,
} from "./mcp.js";

const [command, ...args] = process.argv.slice(2);

try {
  if (command === "contracts") {
    process.stdout.write(JSON.stringify({ settings: SETTINGS_CONTRACT }) + "\n");
  } else if (command === "settings") {
    const [home, file, declaredPath] = args;
    if (!home || (file !== "config.toml" && file !== "tui.toml") || !declaredPath) usage();
    const declared = JSON.parse(await readFile(declaredPath, "utf8")) as Record<string, unknown>;
    await reconcileSettings(home, file, declared);
  } else if (command === "trust") {
    let all = false;
    let verbose = false;
    const paths: string[] = [];

    for (const arg of args) {
      if (arg === "--all") {
        all = true;
      } else if (arg === "-v" || arg === "--verbose") {
        verbose = true;
      } else if (!arg.startsWith("-")) {
        paths.push(arg);
      }
    }

    const result = await reconcileTrust({
      explicitPaths: paths,
      all,
      verbose,
    });

    if (!result.claudeOk || !result.codexOk) {
      process.exit(1);
    }
  } else if (command === "mcp") {
    let harness: HarnessKind | undefined;
    let inventoryPath: string | undefined;
    let validate = false;
    let os: string | undefined;
    let container: boolean | undefined;

    for (const arg of args) {
      if (arg === "--validate") {
        validate = true;
      } else if (arg.startsWith("--harness=")) {
        harness = arg.slice("--harness=".length) as HarnessKind;
      } else if (arg.startsWith("--inventory=")) {
        inventoryPath = arg.slice("--inventory=".length);
      } else if (arg.startsWith("--os=")) {
        os = arg.slice("--os=".length);
      } else if (arg.startsWith("--container=")) {
        container = arg.slice("--container=".length) === "true";
      }
    }

    let rawContent: string;
    if (inventoryPath) {
      rawContent = await readFile(inventoryPath, "utf8");
    } else {
      const chunks: Buffer[] = [];
      for await (const chunk of process.stdin) {
        chunks.push(typeof chunk === "string" ? Buffer.from(chunk) : (chunk as Buffer));
      }
      rawContent = Buffer.concat(chunks).toString("utf8");
    }

    const parsed = parseInventoryContent(rawContent);
    const servers = extractServers(parsed);

    if (validate) {
      validateInventory(servers);
      process.exit(0);
    }

    if (!harness) {
      process.stderr.write("settings-reconcile: error: missing required --harness=<claude|codex|omp>\n");
      usage();
    }

    const manifest = synthesizeMcpManifest(harness, servers, { os, container, harness });
    process.stdout.write(manifest);
  } else {
    usage();
  }
} catch (error) {
  // The reconciler's failures are operator-actionable (a foreign symlink in the
  // managed target tree, drifted state) — report the reason, not a stack trace
  // through the compiled single-file bundle.
  process.stderr.write(
    `settings-reconcile: ${error instanceof Error ? error.message : String(error)}\n`,
  );
  process.exit(1);
}

function usage(): never {
  process.stderr.write("Usage: settings-reconcile <contracts|settings|trust|mcp> ...\n");
  process.exit(2);
}
