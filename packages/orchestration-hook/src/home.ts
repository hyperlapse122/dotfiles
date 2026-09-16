/**
 * Shared HOME resolution for the orchestration hook's non-role modules.
 *
 * An empty HOME must not defeat the fallback: joining a payload path onto ""
 * makes every managed file unreadable and the envelope silently empty.
 */

import { homedir } from "node:os";

export function resolveHome(env: NodeJS.ProcessEnv): string {
  const home = env["HOME"];
  return home !== undefined && home !== "" ? home : homedir();
}
