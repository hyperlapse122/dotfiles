import * as net from "node:net";

const SEND_TIMEOUT_MS = 500;

// WAVEFORM IDS MIRROR crates/mxm4-haptic/src/lib.rs (WAVEFORMS). The Rust
// const is the source of truth; test/drift-guard.test.ts asserts parity.
// The firmware enum has a GAP: ids run 0x00..0x0E contiguously, then
// 0x0F..0x1A are unused and WHISPER COLLISION jumps to 0x1B (27), NOT 15.
// Do NOT "fix" this to a contiguous 0..15.
//
// Feature 0x19B0 (HAPTIC) and its waveform set are NOT in Logitech's public
// HID++ 2.0 docs; the catalogue is community reverse-engineered and
// cross-verified against four independent impls (canonical = Solaar):
// - Solaar HapticWaveForms enum (1st source):
//   https://github.com/pwr-Solaar/Solaar/blob/f68230b83d2ea83c222e1bdfc7f404777f78dc1b/lib/logitech_receiver/hidpp20_constants.py#L368-L385
// - Solaar HAPTIC = 0x19B0 + PlayHapticWaveForm setting (write_fnid 0x40):
//   https://github.com/pwr-Solaar/Solaar/blob/f68230b83d2ea83c222e1bdfc7f404777f78dc1b/lib/logitech_receiver/settings_templates.py#L4411-L4432
// - JuhLabs/juhradial-mx Mx4HapticPattern (Rust, same enum):
//   https://github.com/JuhLabs/juhradial-mx/blob/48939bae45fd074b209264f0cafd709844a4a996/daemon/src/hidpp/patterns.rs#L77-L166
// - olafnew/MasterMice raw HID++ haptic packets (func 0x04 = 0x4A play):
//   https://github.com/olafnew/MasterMice/blob/878f294e64ea5c527997a238de4afc1a0b5650c/service/internal/hidpp/haptic.go#L106-L159
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

const WAVEFORM_NAMES: ReadonlySet<WaveformName> = new Set(WAVEFORMS.map(([name]) => name));

// Runtime guard for plain-JS callers that bypass the `WaveformName` type;
// typed TypeScript callers are already constrained at compile time. Keep it:
// it is not dead code despite `sendCommand` declaring a `WaveformName` param.
function isWaveformName(name: string): name is WaveformName {
  return WAVEFORM_NAMES.has(name as WaveformName);
}

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

// Endpoint shared byte-for-byte with the Rust daemon's socket_path()
// (crates/mxm4-haptic/src/lib.rs); the two MUST agree or the client connects
// nowhere. Node implements local IPC on Windows via named pipes, so a
// \\.\pipe path connects to the daemon's CreateNamedPipeW server. Security
// note: this is the machine-global \\.\pipe namespace, not the per-user POSIX
// runtime dir — the daemon relies on the pipe's default ACL (crate README
// Windows caveat).
const WINDOWS_PIPE_PATH = "\\\\.\\pipe\\mxm4-haptic";

// POSIX resolver: XDG_RUNTIME_DIR (Linux) -> TMPDIR (macOS launchd's per-user
// DARWIN_USER_TEMP_DIR) -> /tmp. Always resolves, so an absent daemon surfaces
// later as SocketMissingError rather than a "runtime dir unset" failure.
function socketPath(): string {
  if (process.platform === "win32") {
    return WINDOWS_PIPE_PATH;
  }
  const dir = nonEmptyEnv("XDG_RUNTIME_DIR") ?? nonEmptyEnv("TMPDIR") ?? "/tmp";
  return `${dir.replace(/\/+$/, "")}/mxm4-haptic.sock`;
}

function nonEmptyEnv(name: string): string | undefined {
  const value = process.env[name];
  return value !== undefined && value.length > 0 ? value : undefined;
}

/**
 * Send one waveform command to the mxm4-hapticd AF_UNIX socket.
 *
 * Await this. Firing then exiting the process without awaiting may DROP the
 * pulse — Node buffers writes; the Rust client flushed synchronously on socket
 * drop.
 */
export async function sendCommand(name: WaveformName): Promise<void> {
  if (!isWaveformName(name)) {
    throw new UnknownWaveformError(name);
  }

  const path = socketPath();
  const payload = `${name}\n`;

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
