import assert from "node:assert/strict";
import { pathToFileURL } from "node:url";

type Handler = (...args: any[]) => unknown;
const handlers = new Map<string, Handler>();
const calls: string[][] = [];
let rejectExec = false;

const api = {
  on(event: string, handler: Handler) {
    handlers.set(event, handler);
  },
  async exec(command: string, args: string[]) {
    calls.push([command, ...args]);
    if (rejectExec) throw new Error("daemon unavailable");
    return { stdout: "", stderr: "", code: 0 };
  },
};

const extensionPath = process.argv[2];
assert.ok(extensionPath, "usage: test-omp-haptic-extension.ts RENDERED_EXTENSION");
const extension = await import(pathToFileURL(extensionPath).href);
extension.default(api);

const trigger = async (event: string, ...args: unknown[]) => {
  const handler = handlers.get(event);
  assert.ok(handler, `missing ${event} handler`);
  await handler(...args);
};
const ui = { hasUI: true };

await trigger("agent_start");
await trigger("after_provider_response", { status: 500 });
await trigger("agent_end", {}, ui);
assert.equal(calls.at(-1)?.at(-1), "MAD");

await trigger("agent_start");
await trigger("agent_end", {}, ui);
assert.equal(calls.at(-1)?.at(-1), "COMPLETED");

await trigger("tool_call", { toolName: "ASK" }, ui);
assert.equal(calls.at(-1)?.at(-1), "RINGING");

const count = calls.length;
await trigger("tool_call", { toolName: "read" }, ui);
await trigger("agent_end", {}, { hasUI: false });
assert.equal(calls.length, count);

rejectExec = true;
await trigger("tool_call", { toolName: "ask" }, ui);

console.log("omp haptic extension tests passed");
