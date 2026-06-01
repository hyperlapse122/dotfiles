import { defineConfig } from "tsdown";

export default defineConfig({
  entry: ["./src/index.ts"],
  deps: {
    neverBundle: ["@opencode-ai/plugin"],
    alwaysBundle: ["@h82/mxm4-haptic", "ts-pattern"],
    onlyBundle: false,
  },
  platform: "node",
  target: "esnext",
  format: "esm",
});
