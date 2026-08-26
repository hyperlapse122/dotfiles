import assert from "node:assert/strict";
import * as fs from "node:fs";
import * as net from "node:net";
import * as os from "node:os";
import * as path from "node:path";
import { pathToFileURL } from "node:url";
import { describe, test } from "vite-plus/test";

import {
  createOmpHapticPlugin,
  type OmpExtensionApi,
  type OmpHapticConfig,
} from "../src/omp-plugin.ts";
import type { WaveformName } from "../src/index.ts";

const CONFIG: OmpHapticConfig = {
  settled: "COMPLETED",
  failed: "MAD",
  question: "RINGING",
};

type Handler = (
  event: Record<string, unknown>,
  context: { hasUI: boolean },
) => void | Promise<void>;

describe("OMP haptic plugin", () => {
  test("registers only the four legacy event handlers", () => {
    const harness = createHarness();

    createOmpHapticPlugin(CONFIG, async () => {})(harness.api);

    assert.deepEqual(harness.registrations, [
      "on:agent_start",
      "on:after_provider_response",
      "on:agent_end",
      "on:tool_call",
    ]);
  });

  test("resets status and uses only the last numeric provider status", async () => {
    const sent: WaveformName[] = [];
    const harness = createHarness();
    createOmpHapticPlugin(CONFIG, async (waveform) => {
      sent.push(waveform);
    })(harness.api);

    await harness.emit("agent_start");
    await harness.emit("after_provider_response", { status: 503 });
    await harness.emit("after_provider_response", { status: "200" });
    await harness.emit("agent_end");

    await harness.emit("agent_start");
    await harness.emit("after_provider_response", { status: 500 });
    await harness.emit("after_provider_response", { status: 399 });
    await harness.emit("after_provider_response", { status: null });
    await harness.emit("agent_end");

    await harness.emit("agent_start");
    await harness.emit("agent_end");

    assert.deepEqual(sent, ["MAD", "COMPLETED", "COMPLETED"]);
  });

  test("gates completion and case-insensitive ask events on a UI context", async () => {
    const sent: WaveformName[] = [];
    const harness = createHarness();
    createOmpHapticPlugin(CONFIG, async (waveform) => {
      sent.push(waveform);
    })(harness.api);

    await harness.emit("agent_end", {}, false);
    await harness.emit("tool_call", { toolName: "ASK" });
    await harness.emit("tool_call", { toolName: "ask" }, false);
    await harness.emit("tool_call", { toolName: "shell" });
    await harness.emit("tool_call", { toolName: 42 });
    await harness.emit("tool_call", {});

    assert.deepEqual(sent, ["RINGING"]);
  });

  test("absorbs synchronous and asynchronous delivery failures", async () => {
    const failures: Array<() => Promise<void>> = [
      async () => {
        throw Object.assign(new Error("missing"), { code: "ENOENT" });
      },
      async () => {
        throw Object.assign(new Error("refused"), { code: "ECONNREFUSED" });
      },
      async () => {
        throw new Error("timeout");
      },
      async () => {
        throw new Error("early close");
      },
      () => {
        throw new Error("synchronous failure");
      },
    ];

    for (const fail of failures) {
      const harness = createHarness();
      createOmpHapticPlugin(CONFIG, fail)(harness.api);
      await assert.doesNotReject(harness.emit("agent_end"));
      await assert.doesNotReject(harness.emit("tool_call", { toolName: "ask" }));
      assert.deepEqual(harness.registrations, [
        "on:agent_start",
        "on:after_provider_response",
        "on:agent_end",
        "on:tool_call",
      ]);
    }
  });
});

describe("OMP plugin bundle isolation", () => {
  test("imports without workspace dependencies and sends through the bundled client", async () => {
    const bundle = path.resolve("dist/omp-plugin/index.js");
    assert.ok(fs.existsSync(bundle), "run the configured build task before the package tests");

    const source = fs.readFileSync(bundle, "utf8");
    const imports = [...source.matchAll(/(?:from\s*|import\s*(?:\(\s*)?)["']([^"']+)["']/g)].map(
      (match) => match[1],
    );
    assert.deepEqual(
      imports.filter((specifier) => !specifier.startsWith("node:")),
      [],
      `bundle contains non-builtin runtime imports: ${imports.join(", ")}`,
    );

    const root = fs.mkdtempSync(path.join(os.tmpdir(), "omp-mxm4-haptic-"));
    const packageDir = path.join(root, "package");
    const runtimeDir = path.join(root, "runtime");
    const isolatedBundle = path.join(packageDir, "dist", "index.js");
    const socketPath = path.join(runtimeDir, "mxm4-haptic.sock");
    fs.mkdirSync(path.dirname(isolatedBundle), { recursive: true });
    fs.mkdirSync(runtimeDir);
    fs.copyFileSync(bundle, isolatedBundle);
    fs.writeFileSync(
      path.join(packageDir, "package.json"),
      JSON.stringify({
        name: "@h82/omp-mxm4-haptic",
        version: "0.0.0",
        private: true,
        type: "module",
        omp: { extensions: ["./dist/index.js"] },
        mxm4Haptic: { waveforms: CONFIG },
      }),
    );

    const originalXdg = process.env.XDG_RUNTIME_DIR;
    const originalPath = process.env.PATH;
    const received = receiveOneCommand(socketPath);

    try {
      process.env.XDG_RUNTIME_DIR = runtimeDir;
      process.env.PATH = "";
      await received.ready;
      // This test intentionally exercises loading a copied runtime-selected plugin entry.
      const module = (await import(`${pathToFileURL(isolatedBundle).href}?isolated`)) as {
        default: (api: OmpExtensionApi) => void;
      };
      assert.equal(typeof module.default, "function");

      const harness = createHarness();
      module.default(harness.api);
      await harness.emit("tool_call", { toolName: "AsK" });
      assert.equal(await received.value, "RINGING\n");
      assert.deepEqual(harness.registrations, [
        "on:agent_start",
        "on:after_provider_response",
        "on:agent_end",
        "on:tool_call",
      ]);
    } finally {
      restoreEnv("XDG_RUNTIME_DIR", originalXdg);
      restoreEnv("PATH", originalPath);
      await received.close();
      fs.rmSync(root, { force: true, recursive: true });
    }
  });
});

function createHarness(): {
  api: OmpExtensionApi;
  emit: (event: string, payload?: Record<string, unknown>, hasUI?: boolean) => Promise<void>;
  registrations: string[];
} {
  const handlers = new Map<string, Handler>();
  const registrations: string[] = [];
  const api = new Proxy(
    {},
    {
      get(_target, property) {
        if (property === "on") {
          return (event: string, handler: Handler) => {
            registrations.push(`on:${event}`);
            handlers.set(event, handler);
          };
        }
        return (..._arguments: unknown[]) => {
          registrations.push(String(property));
        };
      },
    },
  ) as OmpExtensionApi;

  return {
    api,
    registrations,
    async emit(event, payload = {}, hasUI = true) {
      const handler = handlers.get(event);
      assert.ok(handler, `missing ${event} handler`);
      await handler(payload, { hasUI });
    },
  };
}

function receiveOneCommand(socketPath: string): {
  close: () => Promise<void>;
  ready: Promise<void>;
  value: Promise<string>;
} {
  let resolveValue: (value: string) => void = () => {};
  let rejectValue: (reason?: unknown) => void = () => {};
  const value = new Promise<string>((resolve, reject) => {
    resolveValue = resolve;
    rejectValue = reject;
  });
  const sockets = new Set<net.Socket>();
  const server = net.createServer((socket) => {
    sockets.add(socket);
    const chunks: Buffer[] = [];
    socket.on("data", (chunk) => chunks.push(Buffer.from(chunk)));
    socket.on("end", () => {
      resolveValue(Buffer.concat(chunks).toString("utf8"));
      socket.end();
    });
    socket.on("error", rejectValue);
    socket.on("close", () => sockets.delete(socket));
  });
  const ready = new Promise<void>((resolve, reject) => {
    server.once("error", reject);
    server.listen(socketPath, resolve);
  });

  return {
    ready,
    value,
    async close() {
      for (const socket of sockets) socket.destroy();
      if (!server.listening) return;
      await new Promise<void>((resolve, reject) => {
        server.close((error) => (error ? reject(error) : resolve()));
      });
    },
  };
}

function restoreEnv(name: string, value: string | undefined): void {
  if (value === undefined) {
    delete process.env[name];
  } else {
    process.env[name] = value;
  }
}
