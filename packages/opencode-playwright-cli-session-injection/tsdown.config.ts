import { defineConfig } from "tsdown";

export default defineConfig({
  entry: ["./src/index.ts"],
  deps: {
    neverBundle: ["@opencode-ai/plugin"],
    alwaysBundle: ["slugify"],
    onlyBundle: false,
  },
  platform: "node",
  target: "esnext",
  format: "esm",
});
