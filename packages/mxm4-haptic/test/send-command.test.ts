import assert from "node:assert/strict";
import * as fs from "node:fs";
import * as net from "node:net";
import * as os from "node:os";
import * as path from "node:path";
import { describe, test } from "node:test";

import {
  sendCommand,
  waveformId,
  waveformNames,
  WAVEFORMS,
  SocketMissingError,
  XdgRuntimeDirUnsetError,
  UnknownWaveformError,
  HapticTimeoutError,
  ConnectionRefusedError,
} from "../src/index.ts";

describe("sendCommand", () => {
  test("flush-confirms a valid waveform command", async () => {
    const runtime = createRuntimeDir();
    let resolveReceived: (value: string) => void = () => {};
    let rejectReceived: (reason?: unknown) => void = () => {};
    const received = new Promise<string>((resolve, reject) => {
      resolveReceived = resolve;
      rejectReceived = reject;
    });
    const server = net.createServer((socket: SocketLike) => {
      const chunks: string[] = [];

      socket.setEncoding("utf8");
      socket.on("data", (chunk) => {
        chunks.push(String(chunk));
      });
      socket.on("end", () => {
        resolveReceived(chunks.join(""));
        socket.end();
      });
      socket.on("error", rejectReceived);
    });

    try {
      await listen(server, runtime.socketPath);

      await sendCommand("SHARP COLLISION");
      assert.equal(await received, "SHARP COLLISION\n");
    } finally {
      await closeServer(server);
      runtime.cleanup();
    }
  });

  test("maps ENOENT to SocketMissingError", async () => {
    const runtime = createRuntimeDir();

    try {
      const rejection = await assertRejectsAs(sendCommand("KNOCK"), SocketMissingError);
      assert.equal(errorCode(rejection), "SOCKET_MISSING");
    } finally {
      runtime.cleanup();
    }
  });

  test("rejects when XDG_RUNTIME_DIR is unset", async () => {
    const runtime = createRuntimeDir();

    try {
      delete process.env.XDG_RUNTIME_DIR;

      await assert.rejects(sendCommand("KNOCK"), XdgRuntimeDirUnsetError);
    } finally {
      runtime.cleanup();
    }
  });

  test("rejects unknown waveforms before connecting", async () => {
    const runtime = createRuntimeDir();
    let connections = 0;
    const server = net.createServer((socket: SocketLike) => {
      connections += 1;
      socket.destroy();
    });

    try {
      await listen(server, runtime.socketPath);

      await assert.rejects(sendCommand("bogus"), UnknownWaveformError);
      assert.equal(connections, 0);
    } finally {
      await closeServer(server);
      runtime.cleanup();
    }
  });

  test("rejects when the daemon keeps the connection open", async () => {
    const runtime = createRuntimeDir();
    const sockets = new Set<SocketLike>();
    const server = net.createServer((socket: SocketLike) => {
      sockets.add(socket);
      socket.on("close", () => {
        sockets.delete(socket);
      });
    });

    try {
      await listen(server, runtime.socketPath);

      const started = Date.now();
      await assert.rejects(sendCommand("WAVE"), HapticTimeoutError);
      const elapsed = Date.now() - started;

      assert.ok(elapsed >= 450, `timeout fired too early after ${elapsed}ms`);
      assert.ok(elapsed < 2_000, `timeout fired too late after ${elapsed}ms`);
    } finally {
      await closeServer(server, sockets);
      runtime.cleanup();
    }
  });
});

type RuntimeDir = {
  cleanup: () => void;
  socketPath: string;
};

type SocketLike = {
  destroy: () => void;
  end: () => void;
  on: {
    (event: "close" | "end", listener: () => void): void;
    (event: "data", listener: (chunk: string | Uint8Array) => void): void;
    (event: "error", listener: (error: unknown) => void): void;
  };
  setEncoding: (encoding: "utf8") => void;
};

function createRuntimeDir(): RuntimeDir {
  const originalXdgRuntimeDir = process.env.XDG_RUNTIME_DIR;
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "mxm4-"));
  const socketPath = path.join(dir, "mxm4-haptic.sock");

  process.env.XDG_RUNTIME_DIR = dir;

  return {
    socketPath,
    cleanup() {
      restoreXdgRuntimeDir(originalXdgRuntimeDir);
      fs.rmSync(socketPath, { force: true });
      fs.rmSync(dir, { force: true, recursive: true });
    },
  };
}

function restoreXdgRuntimeDir(value: string | undefined): void {
  if (value === undefined) {
    delete process.env.XDG_RUNTIME_DIR;
    return;
  }

  process.env.XDG_RUNTIME_DIR = value;
}

async function listen(server: net.Server, socketPath: string): Promise<void> {
  await new Promise<void>((resolve) => {
    server.listen(socketPath, () => {
      resolve();
    });
  });
}

async function closeServer(server: net.Server, sockets = new Set<SocketLike>()): Promise<void> {
  for (const socket of sockets) {
    socket.destroy();
  }

  if (!server.listening) {
    return;
  }

  await new Promise<void>((resolve, reject) => {
    server.close((error: Error | undefined) => {
      if (error) {
        reject(error);
        return;
      }

      resolve();
    });
  });
}

async function assertRejectsAs(promise: Promise<unknown>, ErrorClass: Function): Promise<unknown> {
  let rejection: unknown;

  await assert.rejects(
    promise.catch((error: unknown) => {
      rejection = error;
      throw error;
    }),
    ErrorClass,
  );

  return rejection;
}

function errorCode(error: unknown): unknown {
  if (error instanceof Error && "code" in error) {
    return error.code;
  }

  return undefined;
}
