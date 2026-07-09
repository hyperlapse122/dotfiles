import { defineConfig } from "vite-plus";

// Workspace-root Vite+ config. Holds the SHARED toolchain settings for every
// member: Oxlint (lint), Oxfmt (fmt), and the staged-file check. Per-member
// build (`pack`), test, and task wiring live in each member's vite.config.ts.
export default defineConfig({
  lint: {
    // Keep the migrate-installed JS plugin so `prefer-vite-plus-imports`
    // enforces the vite -> vite-plus / vitest -> vite-plus/test rewrites.
    jsPlugins: [{ name: "vite-plus", specifier: "vite-plus/oxlint-plugin" }],
    rules: {
      "vite-plus/prefer-vite-plus-imports": "error",
      // Port of the old per-member ESLint rule: allow intentionally-unused
      // identifiers when prefixed with `_`.
      "no-unused-vars": [
        "error",
        {
          argsIgnorePattern: "^_",
          varsIgnorePattern: "^_",
          caughtErrorsIgnorePattern: "^_",
        },
      ],
    },
    options: { typeAware: true, typeCheck: true },
    ignorePatterns: ["**/dist/**"],
  },
  fmt: {
    // Ported from the old shared .prettierrc.json (printWidth 100, semi true).
    printWidth: 100,
    semi: true,
    sortPackageJson: false,
    // Ported from the old .prettierignore: format .ts source only. JSON
    // (tsconfig comments/trailing commas, Bun-managed manifests) and Markdown
    // are left untouched, as is build output.
    ignorePatterns: ["**/dist/**", "**/*.json", "**/*.md"],
  },
  // `vp staged` replaces lint-staged: format + lint + type-check staged sources.
  staged: {
    "*.{ts,mts,cts}": "vp check --fix",
  },
});
