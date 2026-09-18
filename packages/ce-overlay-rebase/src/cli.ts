import { readFile, writeFile } from "node:fs/promises";
import { classifyFailure } from "./classify.js";
import { decideDispatch } from "./decide.js";
import {
  type Marker,
  type MarkerDocument,
  type MarkerEvent,
  transitionMarker,
  validateMarker,
} from "./marker.js";

export interface CliIo {
  stdin?: string;
  stdout?: (msg: string) => void;
  stderr?: (msg: string) => void;
}

async function readInput(args: string[], io?: CliIo): Promise<string> {
  if (io?.stdin !== undefined) {
    return io.stdin;
  }
  const fileArg = args.find((a) => !a.startsWith("-"));
  if (fileArg && fileArg !== "-") {
    return await readFile(fileArg, "utf-8");
  }
  const chunks: Buffer[] = [];
  for await (const chunk of process.stdin) {
    chunks.push(typeof chunk === "string" ? Buffer.from(chunk) : chunk);
  }
  return Buffer.concat(chunks).toString("utf-8");
}

function unwrapMarker(data: unknown): unknown {
  return typeof data === "object" && data !== null && "ceOverlayRebase" in data
    ? (data as MarkerDocument).ceOverlayRebase
    : data;
}

export async function runCli(args: string[], io?: CliIo): Promise<number> {
  const writeOut = io?.stdout ?? ((msg: string) => process.stdout.write(msg));
  const writeErr = io?.stderr ?? ((msg: string) => process.stderr.write(msg));

  const command = args[0];

  if (!command || command === "--help" || command === "-h") {
    writeOut(
      "Usage: ce-overlay-rebase <validate-marker|write-marker|decide|classify|transition> [options] [file]\n",
    );
    return 0;
  }

  const subArgs = args.slice(1);

  if (command === "validate-marker") {
    try {
      const raw = await readInput(subArgs, io);
      const data = JSON.parse(raw);
      const res = validateMarker(unwrapMarker(data));

      if (!res.valid) {
        writeErr(`Validation failed:\n  ${res.errors.join("\n  ")}\n`);
        return 1;
      }
      writeOut(JSON.stringify({ valid: true }, null, 2) + "\n");
      return 0;
    } catch (err) {
      writeErr(`Validation failed: ${String(err)}\n`);
      return 1;
    }
  }

  if (command === "write-marker") {
    try {
      let outPath: string | null = null;
      const filteredArgs: string[] = [];
      for (let i = 0; i < subArgs.length; i++) {
        if (subArgs[i] === "--out" && i + 1 < subArgs.length) {
          outPath = subArgs[i + 1]!;
          i++;
        } else {
          filteredArgs.push(subArgs[i]!);
        }
      }

      const raw = await readInput(filteredArgs, io);
      const data = JSON.parse(raw);
      const markerObj = unwrapMarker(data) as Marker;

      const res = validateMarker(markerObj);
      if (!res.valid) {
        writeErr(`Marker refused: validation failed:\n  ${res.errors.join("\n  ")}\n`);
        return 1;
      }

      const doc: MarkerDocument = { ceOverlayRebase: markerObj };
      const formatted = JSON.stringify(doc, null, 2) + "\n";

      if (outPath) {
        await writeFile(outPath, formatted, "utf-8");
      } else {
        writeOut(formatted);
      }
      return 0;
    } catch (err) {
      writeErr(`Marker refused: ${String(err)}\n`);
      return 1;
    }
  }

  if (command === "decide") {
    try {
      const raw = await readInput(subArgs, io);
      const input = JSON.parse(raw);
      const result = decideDispatch(input);
      writeOut(JSON.stringify(result, null, 2) + "\n");
      return 0;
    } catch (err) {
      writeErr(`Decision failed: ${String(err)}\n`);
      return 1;
    }
  }

  if (command === "classify") {
    try {
      const raw = await readInput(subArgs, io);
      const input = JSON.parse(raw);
      const failureClass = classifyFailure(input);
      writeOut(JSON.stringify({ failureClass }, null, 2) + "\n");
      return 0;
    } catch (err) {
      writeErr(`Classification failed: ${String(err)}\n`);
      return 1;
    }
  }

  if (command === "transition") {
    try {
      const raw = await readInput(subArgs, io);
      const input = JSON.parse(raw) as {
        currentMarker: Marker;
        event: MarkerEvent;
      };
      const marker = transitionMarker(input.currentMarker, input.event);
      writeOut(JSON.stringify(marker, null, 2) + "\n");
      return 0;
    } catch (err) {
      writeErr(`Transition failed: ${String(err)}\n`);
      return 1;
    }
  }

  writeErr(`Unknown command: ${command}\n`);
  return 1;
}

if (process.argv[1] && process.argv[1].endsWith("cli.ts")) {
  void runCli(process.argv.slice(2))
    .then((code) => {
      if (code !== 0) {
        process.exit(code);
      }
    })
    .catch((err: unknown) => {
      process.stderr.write(`CLI crashed: ${String(err)}\n`);
      process.exit(1);
    });
}
