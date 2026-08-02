import assert from "node:assert/strict";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { pathToFileURL } from "node:url";

type Handler = (event: Record<string, unknown>, context: { hasUI: boolean }) => unknown;
const packageRoot = process.argv[2];
assert.ok(packageRoot, "usage: test-omp-haptic-plugin.ts DEPLOYED_PACKAGE_ROOT");
const manifest = JSON.parse(await readFile(resolve(packageRoot, "package.json"), "utf8"));
assert.equal(manifest.name, "@h82/omp-mxm4-haptic");
assert.deepEqual(manifest.omp?.extensions, ["./dist/index.js"]);

const runtime = await mkdtemp(join(tmpdir(), "omp-haptic-plugin."));
const socket = join(runtime, "mxm4-haptic.sock");
process.env.XDG_RUNTIME_DIR = runtime;
const received: string[] = [];
const server = createServer(connection => {
  connection.setEncoding("utf8");
  connection.on("data", data => received.push(data));
});
await new Promise<void>((accept, reject) => server.listen(socket, accept).once("error", reject));
try {
  // The deployed entry is selected from the runtime package manifest; loading that boundary is the test.
  const module = await import(pathToFileURL(resolve(packageRoot, manifest.omp.extensions[0])).href);
  assert.equal(typeof module.default, "function");
  const handlers = new Map<string, Handler[]>();
  const api = new Proxy({
    on(event: string, handler: Handler) {
      const values = handlers.get(event) ?? [];
      values.push(handler);
      handlers.set(event, values);
    },
  }, {
    get(target, property) {
      assert.ok(property in target, `plugin registered unexpected API surface ${String(property)}`);
      return target[property as keyof typeof target];
    },
  });
  module.default(api);
  assert.deepEqual([...handlers.keys()].sort(), ["after_provider_response", "agent_end", "agent_start", "tool_call"]);
  assert.ok([...handlers.values()].every(values => values.length === 1), "exactly one haptic owner must register each event");
  const trigger = async (event: string, payload: Record<string, unknown> = {}, hasUI = true) => {
    const handler = handlers.get(event)?.[0];
    assert.ok(handler, `missing ${event}`);
    await handler(payload, { hasUI });
  };
  const waitFor = async (count: number) => {
    for (let attempt = 0; attempt < 100 && received.length < count; attempt++) await Bun.sleep(5);
    assert.equal(received.length, count);
  };

  await trigger("agent_start");
  await trigger("after_provider_response", { status: 200 });
  await trigger("after_provider_response", { status: "500" });
  await trigger("after_provider_response", { status: 503 });
  await trigger("agent_end");
  await waitFor(1);
  assert.equal(received[0], `${manifest.mxm4Haptic.waveforms.failed}\n`);

  await trigger("agent_start");
  await trigger("agent_end");
  await waitFor(2);
  assert.equal(received[1], `${manifest.mxm4Haptic.waveforms.settled}\n`);

  await trigger("tool_call", { toolName: "ASK" });
  await waitFor(3);
  assert.equal(received[2], `${manifest.mxm4Haptic.waveforms.question}\n`);
  await trigger("tool_call", { toolName: "read" });
  await trigger("tool_call", { toolName: 42 });
  await trigger("tool_call", { toolName: "ask" }, false);
  await trigger("agent_end", {}, false);
  assert.equal(received.length, 3);

  await new Promise<void>(accept => server.close(() => accept()));
  await trigger("tool_call", { toolName: "ask" });
  await trigger("agent_end");
  assert.equal(received.length, 3, "delivery errors remain silent and non-fatal");
} finally {
  if (server.listening) await new Promise<void>(accept => server.close(() => accept()));
  await rm(runtime, { recursive: true, force: true });
}
console.log("omp haptic plugin event tests passed");
