import { DEFAULT_HOST, DEFAULT_PORT } from "./proxy.js";
import { listenSidecar } from "./server.js";

function readPort(value: string | undefined): number {
  if (value === undefined || value === "") return DEFAULT_PORT;
  const port = Number(value);
  if (!Number.isInteger(port) || port < 1 || port > 65_535) {
    throw new Error("ANTIGRAVITY_SIDECAR_PORT must be an integer from 1 through 65535");
  }
  return port;
}

const configuredHost = process.env["ANTIGRAVITY_SIDECAR_HOST"];
if (configuredHost !== undefined && configuredHost !== DEFAULT_HOST) {
  process.stderr.write(`antigravity-sidecar: host must be ${DEFAULT_HOST}\n`);
  process.exitCode = 1;
} else {
  try {
    const sidecar = await listenSidecar({
      port: readPort(process.env["ANTIGRAVITY_SIDECAR_PORT"]),
    });
    let stopping = false;
    const stop = () => {
      if (stopping) return;
      stopping = true;
      void sidecar
        .close()
        .then(() => process.exit(0))
        .catch(() => process.exit(1));
    };
    process.once("SIGINT", stop);
    process.once("SIGTERM", stop);
  } catch {
    process.stderr.write("antigravity-sidecar: failed to listen\n");
    process.exitCode = 1;
  }
}
