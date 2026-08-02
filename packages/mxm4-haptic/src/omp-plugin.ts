import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import { isWaveformName, sendCommand, type WaveformName } from "./index.js";

const QUESTION_TOOL = "ask";
const PACKAGE_JSON_PATH = join(dirname(fileURLToPath(import.meta.url)), "..", "package.json");

type OmpEventHandler = (
  event: Record<string, unknown>,
  context: OmpContext,
) => void | Promise<void>;

export interface OmpExtensionApi {
  on(event: string, handler: OmpEventHandler): void;
}

interface OmpContext {
  hasUI: boolean;
}

export interface OmpHapticConfig {
  settled: WaveformName;
  failed: WaveformName;
  question: WaveformName;
}

type SendHaptic = (waveform: WaveformName) => Promise<void>;

export function createOmpHapticPlugin(
  config: OmpHapticConfig,
  send: SendHaptic = sendCommand,
): (pi: OmpExtensionApi) => void {
  return (pi) => {
    let lastProviderStatus: number | undefined;

    async function pulse(waveform: WaveformName): Promise<void> {
      try {
        await send(waveform);
      } catch {
        // Delivery is optional; it must never affect an agent turn.
      }
    }

    pi.on("agent_start", () => {
      lastProviderStatus = undefined;
    });

    pi.on("after_provider_response", (event) => {
      if (typeof event.status === "number") lastProviderStatus = event.status;
    });

    pi.on("agent_end", async (_event, context) => {
      if (!context.hasUI) return;
      await pulse(
        lastProviderStatus !== undefined && lastProviderStatus >= 400
          ? config.failed
          : config.settled,
      );
    });

    pi.on("tool_call", async (event, context) => {
      if (!context.hasUI) return;
      if (typeof event.toolName === "string" && event.toolName.toLowerCase() === QUESTION_TOOL) {
        await pulse(config.question);
      }
    });
  };
}

export default function ompHapticPlugin(pi: OmpExtensionApi): void {
  createOmpHapticPlugin(readPackageConfig())(pi);
}

function readPackageConfig(): OmpHapticConfig {
  const packageJson = JSON.parse(readFileSync(PACKAGE_JSON_PATH, "utf8")) as unknown;
  const root = getRecord(packageJson, "package.json");
  const config = getRecord(root.mxm4Haptic, "mxm4Haptic");
  const values = getRecord(config.waveforms, "mxm4Haptic.waveforms");

  return {
    settled: readWaveform(values, "settled"),
    failed: readWaveform(values, "failed"),
    question: readWaveform(values, "question"),
  };
}

function getRecord(value: unknown, label: string): Record<string, unknown> {
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    throw new Error(`${label} must be an object`);
  }
  return value as Record<string, unknown>;
}

function readWaveform(config: Record<string, unknown>, key: string): WaveformName {
  const value = config[key];
  if (typeof value !== "string" || !isWaveformName(value)) {
    throw new Error(`mxm4Haptic.waveforms.${key} is not a known mxm4-haptic waveform`);
  }
  return value;
}
