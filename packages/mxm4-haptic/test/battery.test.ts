import assert from "node:assert/strict";
import * as fs from "node:fs";
import * as net from "node:net";
import * as os from "node:os";
import * as path from "node:path";
import { describe, test } from "vite-plus/test";

import { getBatteryStatus, SocketMissingError } from "../src/index.ts";

describe("getBatteryStatus", () => {
  test("queries and parses battery status from server", async () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), "logid-test-"));
    const socketPath = path.join(dir, "logid.sock");
    const origXdg = process.env.XDG_RUNTIME_DIR;
    process.env.XDG_RUNTIME_DIR = dir;

    const server = net.createServer((socket) => {
      socket.setEncoding("utf8");
      socket.on("data", (chunk) => {
        if (chunk.toString().trim() === "BATTERY") {
          socket.write('{"percentage": 85, "status": "Discharging"}\n');
          socket.end();
        }
      });
    });

    try {
      await new Promise<void>((resolve) => server.listen(socketPath, resolve));
      const status = await getBatteryStatus();
      assert.deepEqual(status, {
        percentage: 85,
        status: "Discharging",
      });
    } finally {
      await new Promise<void>((resolve) => server.close(() => resolve()));
      fs.rmSync(socketPath, { force: true });
      fs.rmSync(dir, { force: true, recursive: true });
      if (origXdg) {
        process.env.XDG_RUNTIME_DIR = origXdg;
      } else {
        delete process.env.XDG_RUNTIME_DIR;
      }
    }
  });

  test("handles null response when device not connected", async () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), "logid-test-"));
    const socketPath = path.join(dir, "logid.sock");
    const origXdg = process.env.XDG_RUNTIME_DIR;
    process.env.XDG_RUNTIME_DIR = dir;

    const server = net.createServer((socket) => {
      socket.setEncoding("utf8");
      socket.on("data", (chunk) => {
        if (chunk.toString().trim() === "BATTERY") {
          socket.write("null\n");
          socket.end();
        }
      });
    });

    try {
      await new Promise<void>((resolve) => server.listen(socketPath, resolve));
      const status = await getBatteryStatus();
      assert.equal(status, null);
    } finally {
      await new Promise<void>((resolve) => server.close(() => resolve()));
      fs.rmSync(socketPath, { force: true });
      fs.rmSync(dir, { force: true, recursive: true });
      if (origXdg) {
        process.env.XDG_RUNTIME_DIR = origXdg;
      } else {
        delete process.env.XDG_RUNTIME_DIR;
      }
    }
  });

  test("maps missing socket to SocketMissingError", async () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), "logid-test-"));
    const origXdg = process.env.XDG_RUNTIME_DIR;
    process.env.XDG_RUNTIME_DIR = dir;

    try {
      await assert.rejects(getBatteryStatus(), SocketMissingError);
    } finally {
      fs.rmSync(dir, { force: true, recursive: true });
      if (origXdg) {
        process.env.XDG_RUNTIME_DIR = origXdg;
      } else {
        delete process.env.XDG_RUNTIME_DIR;
      }
    }
  });
});
