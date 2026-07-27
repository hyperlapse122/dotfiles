import { defineConfig } from "vite-plus";

export default defineConfig({
  test: { include: ["test/**/*.test.ts"], server: { deps: { inline: ["vite-plus"] } } },
  run: {
    tasks: {
      typecheck: { command: "tsc -p tsconfig.json --noEmit" },
      test: { command: "vp test" },
    },
  },
});
