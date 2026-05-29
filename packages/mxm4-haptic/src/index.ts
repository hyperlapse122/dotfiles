import * as net from "node:net";

const SEND_TIMEOUT_MS = 500;

// WAVEFORM IDS MIRROR crates/mxm4-haptic/src/lib.rs (WAVEFORMS, lines ~24-41).
// The firmware enum has a GAP between MAD (11) and WHISPER COLLISION (27):
// WHISPER COLLISION = 27, NOT 15. Do NOT "fix" this to a contiguous 0..15.
// Source: logitech_receiver.hidpp20_constants.HapticWaveForms.
export const WAVEFORMS = [
  ["SHARP STATE CHANGE", 0],
  ["DAMP STATE CHANGE", 1],
  ["SHARP COLLISION", 2],
  ["DAMP COLLISION", 3],
  ["SUBTLE COLLISION", 4],
  ["HAPPY ALERT", 5],
  ["ANGRY ALERT", 6],
  ["COMPLETED", 7],
  ["SQUARE", 8],
  ["WAVE", 9],
  ["FIREWORK", 10],
  ["MAD", 11],
  ["KNOCK", 12],
  ["JINGLE", 13],
  ["RINGING", 14],
  ["WHISPER COLLISION", 27],
] as const;

export type WaveformName = (typeof WAVEFORMS)[number][0];

const WAVEFORM_IDS: ReadonlyMap<string, number> = new Map(WAVEFORMS);
const WAVEFORM_NAMES = WAVEFORMS.map(([name]) => name);

export class HapticError<Code extends string = string> extends Error {
  readonly code: Code;

  constructor(code: Code, message: string, options?: ErrorOptions) {
    super(message, options);
    this.name = new.target.name;
    this.code = code;
  }
}

export class UnknownWaveformError extends HapticError<"UNKNOWN_WAVEFORM"> {
  constructor(name: string) {
    super("UNKNOWN_WAVEFORM", `Unknown haptic waveform "${name}".`);
  }
}

export class XdgRuntimeDirUnsetError extends HapticError<"XDG_RUNTIME_DIR_UNSET"> {
  constructor() {
    super(
      "XDG_RUNTIME_DIR_UNSET",
      "XDG_RUNTIME_DIR is unset; cannot locate the mxm4-hapticd socket.",
    );
  }
}

export class SocketMissingError extends HapticError<"SOCKET_MISSING"> {
  constructor(path: string, options?: ErrorOptions) {
    super(
      "SOCKET_MISSING",
      `mxm4-hapticd socket is missing at ${path}; is the daemon running?`,
      options,
    );
  }
}

export class ConnectionRefusedError extends HapticError<"CONNECTION_REFUSED"> {
  constructor(path: string, options?: ErrorOptions) {
    super(
      "CONNECTION_REFUSED",
      `Connection refused by the mxm4-hapticd socket at ${path}.`,
      options,
    );
  }
}

export class HapticTimeoutError extends HapticError<"TIMEOUT"> {
  constructor(path: string) {
    super("TIMEOUT", `Timed out after ${SEND_TIMEOUT_MS}ms sending haptic command to ${path}.`);
  }
}

export function waveformNames(): readonly string[] {
  return WAVEFORM_NAMES;
}

export function waveformId(name: string): number | undefined {
  return WAVEFORM_IDS.get(name.toUpperCase());
}

export function socketPath(): string | undefined {
  const runtimeDir = process.env.XDG_RUNTIME_DIR;
  return runtimeDir ? `${runtimeDir}/mxm4-haptic.sock` : undefined;
}

/**
 * Send one waveform command to the mxm4-hapticd AF_UNIX socket.
 *
 * Await this. Firing then exiting the process without awaiting may DROP the
 * pulse — Node buffers writes; the Rust client flushed synchronously on socket
 * drop.
 */
export async function sendCommand(name: string): Promise<void> {
  if (waveformId(name) === undefined) {
    throw new UnknownWaveformError(name);
  }

  const path = socketPath();
  if (path === undefined) {
    throw new XdgRuntimeDirUnsetError();
  }

  const payload = `${name.toUpperCase()}\n`;

  await new Promise<void>((resolve, reject) => {
    const socket = net.createConnection({ path });
    let settled = false;
    let endRequested = false;

    const timeout = setTimeout(() => {
      rejectOnce(new HapticTimeoutError(path));
      socket.destroy();
    }, SEND_TIMEOUT_MS);

    const clearSendTimeout = () => {
      clearTimeout(timeout);
    };

    const resolveOnce = () => {
      if (settled) {
        return;
      }
      settled = true;
      clearSendTimeout();
      resolve();
    };

    const rejectOnce = (error: Error) => {
      if (settled) {
        return;
      }
      settled = true;
      clearSendTimeout();
      reject(error);
    };

    socket.once("connect", () => {
      try {
        endRequested = true;
        socket.end(payload);
      } catch (error) {
        rejectOnce(toError(error));
        socket.destroy();
      }
    });

    socket.once("error", (error) => {
      rejectOnce(mapSocketError(error, path));
    });

    socket.once("close", (hadError) => {
      if (settled) {
        return;
      }
      if (hadError || !endRequested) {
        rejectOnce(new Error(`Socket closed before haptic command flushed: ${path}`));
        return;
      }
      resolveOnce();
    });
  });
}

type NodeSocketError = Error & { code?: string };

function mapSocketError(error: Error, path: string): Error {
  const socketError = error as NodeSocketError;
  if (socketError.code === "ENOENT") {
    return new SocketMissingError(path, { cause: error });
  }
  if (socketError.code === "ECONNREFUSED") {
    return new ConnectionRefusedError(path, { cause: error });
  }
  return error;
}

function toError(error: unknown): Error {
  if (error instanceof Error) {
    return error;
  }
  return new Error(String(error));
}
