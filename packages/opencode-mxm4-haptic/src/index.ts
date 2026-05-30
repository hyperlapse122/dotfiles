import type { Plugin } from "@opencode-ai/plugin";
import { sendCommand } from "@h82/mxm4-haptic";

export const MXMaster4HapticPlugin: Plugin = async () => {
  return {
    event: async ({ event }) => {
      // Send notification on session completion
      if (event.type === "session.idle") {
        await sendCommand("COMPLETED");
      }
    },
  };
};
