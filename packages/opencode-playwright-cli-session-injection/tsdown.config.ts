import { defineConfig } from "tsdown";

export default defineConfig({
  entry: ["./src/index.ts"],
  deps: {
    neverBundle: ["@opencode-ai/plugin"],
    onlyBundle: false,
  },
  platform: "node",
  target: "esnext",
  format: "esm",
});
