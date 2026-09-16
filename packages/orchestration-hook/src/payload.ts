/**
 * The orchestration payload bodies, read at run time from managed files.
 *
 * Each body has ONE source template under .chezmoitemplates/, rendered over the
 * agents.roster data into a chezmoi-managed target next to the binary's own
 * staging path. The binary reads that rendered file instead of embedding the
 * template bytes, so a roster edit reaches a session through one `chezmoi
 * apply` with no rebuild, and the binary stays host-independent.
 *
 * A missing, unreadable, or empty file yields null. The caller turns that into
 * the harness's empty output under the envelope's atomicity rule: a partial
 * rule set is worse than none, and a hook that threw here would break session
 * start, which is strictly worse than delivering nothing.
 */

import { readFileSync } from "node:fs";
import { join } from "node:path";
import { resolveHome } from "./home.js";

export type PayloadBody = "everyone" | "coordinator";

/** Test and CI-gate override, mirroring omp-orca's DOTFILES_ORCHESTRATION_HOOK. */
const PAYLOAD_DIR_ENV = "DOTFILES_ORCHESTRATION_HOOK_PAYLOAD_DIR";

function payloadDir(env: NodeJS.ProcessEnv): string {
  const configured = env[PAYLOAD_DIR_ENV];
  if (configured !== undefined && configured !== "") return configured;
  return join(resolveHome(env), ".local", "share", "orchestration-hook");
}

export function payloadPath(body: PayloadBody, env: NodeJS.ProcessEnv): string {
  return join(payloadDir(env), `${body}.md`);
}

export function payload(body: PayloadBody, env: NodeJS.ProcessEnv): string | null {
  let text: string;
  try {
    text = readFileSync(payloadPath(body, env), "utf8");
  } catch {
    return null;
  }
  return text === "" ? null : text;
}

export function isPayloadBody(value: string): value is PayloadBody {
  return value === "everyone" || value === "coordinator";
}
