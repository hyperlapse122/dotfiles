import { withLease } from "./lease.js";
import { loadManifest } from "./manifest.js";
import { activateUnit, reconcileAll } from "./reconcile.js";

function printUsage(): void {
  process.stderr.write(
    `Usage:
  command-reconcile activate-unit --manifest <path|json> --unit <id> [--home <path>] [--json]
  command-reconcile reconcile-all --manifest <path|json> [--home <path>] [--prune] [--json]
`,
  );
}

export async function main(argv: string[]): Promise<number> {
  const args = argv.slice(2);
  const command = args[0];

  if (!command || command === "--help" || command === "-h") {
    printUsage();
    return 1;
  }

  let manifestArg = "";
  let unitArg = "";
  let homeArg: string | undefined = undefined;
  let pruneArg = false;
  let jsonArg = false;

  for (let i = 1; i < args.length; i++) {
    const arg = args[i];
    if (arg === "--manifest" && i + 1 < args.length) {
      manifestArg = args[++i] ?? "";
    } else if (arg === "--unit" && i + 1 < args.length) {
      unitArg = args[++i] ?? "";
    } else if (arg === "--home" && i + 1 < args.length) {
      homeArg = args[++i];
    } else if (arg === "--prune") {
      pruneArg = true;
    } else if (arg === "--json") {
      jsonArg = true;
    }
  }

  if (!manifestArg) {
    process.stderr.write("Error: --manifest is required\n");
    printUsage();
    return 1;
  }

  const manifest = await loadManifest(manifestArg);

  if (command === "activate-unit") {
    if (!unitArg) {
      process.stderr.write("Error: --unit is required for activate-unit\n");
      return 1;
    }
    const result = await withLease(homeArg, () => activateUnit(homeArg, manifest, unitArg));
    if (jsonArg) {
      process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
    } else if (result.status === "failed" || result.status === "conflict") {
      process.stderr.write(
        `command-reconcile: activate-unit failed for ${unitArg}: ${result.error ?? result.status}\n`,
      );
    }
    return result.status === "failed" || result.status === "conflict" ? 1 : 0;
  }

  if (command === "reconcile-all") {
    const report = await withLease(homeArg, () => reconcileAll(homeArg, manifest, pruneArg));
    if (jsonArg) {
      process.stdout.write(`${JSON.stringify(report, null, 2)}\n`);
    } else {
      if (report.activated.length > 0) {
        process.stdout.write(`command-reconcile: activated ${report.activated.join(", ")}\n`);
      }
      if (report.pruned.length > 0) {
        process.stdout.write(`command-reconcile: pruned ${report.pruned.join(", ")}\n`);
      }
      for (const conflict of report.conflicts) {
        process.stderr.write(
          `command-reconcile: conflict for ${conflict.id} at ${conflict.path}: ${conflict.reason}\n`,
        );
      }
      for (const fail of report.failed) {
        process.stderr.write(`command-reconcile: failed ${fail.id}: ${fail.error}\n`);
      }
    }
    return report.failed.length > 0 ? 1 : 0;
  }

  process.stderr.write(`Unknown command: ${command}\n`);
  printUsage();
  return 1;
}

if (import.meta.url === `file://${process.argv[1]}`) {
  main(process.argv).then(
    (code) => {
      process.exit(code);
    },
    (err) => {
      process.stderr.write(
        `command-reconcile error: ${err instanceof Error ? err.message : String(err)}\n`,
      );
      process.exit(1);
    },
  );
}
