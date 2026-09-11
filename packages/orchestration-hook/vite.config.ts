import { readFile } from "node:fs/promises";
import { defineConfig } from "vite-plus";

// src/payload.ts imports the two payload bodies as text. `bun build --compile`
// inlines a `with { type: "text" }` import on its own; Vite, which backs the
// test runner, has no loader for the .tmpl extension and would hand the body to
// its JS parser. This plugin gives the test toolchain the same text, so one
// import form serves both and the tests read the real source bytes rather than
// a fixture copy.
const tmplText = {
  name: "orchestration-payload-text",
  enforce: "pre" as const,
  async load(id: string) {
    if (!id.endsWith(".tmpl")) return null;
    return `export default ${JSON.stringify(await readFile(id, "utf8"))};`;
  },
};

export default defineConfig({
  plugins: [tmplText],
  test: {
    include: ["test/**/*.test.ts"],
    server: { deps: { inline: ["vite-plus"] } },
  },
  run: {
    tasks: {
      build: {
        command: "bun build --compile ./src/cli.ts --outfile ./dist/orchestration-hook",
        // Two build inputs live outside this workspace root and out of reach of
        // any `input` base: the locked bun version in .chezmoidata/releases.json
        // (the compiled binary embeds a bun runtime) and the two payload bodies
        // in .chezmoitemplates/, which src/payload.ts embeds as text. The build
        // script exports a digest of each so both enter the cache key here.
        // Without this, `bun build --compile` runs as an external process whose
        // reads automatic tracking cannot see, and a payload edit would replay a
        // cached dist while reporting success.
        env: ["DOTFILES_BUN_VERSION", "DOTFILES_PAYLOAD_DIGEST"],
        input: [
          "src/**",
          "package.json",
          "tsconfig.json",
          "vite.config.ts",
          { pattern: "package.json", base: "workspace" },
          { pattern: "bun.lock", base: "workspace" },
          { pattern: "bunfig.toml", base: "workspace" },
          { pattern: "vite.config.ts", base: "workspace" },
        ],
        output: ["dist/**"],
      },
      typecheck: { command: "tsc -p tsconfig.json --noEmit" },
      test: { command: "vp test" },
    },
  },
});
