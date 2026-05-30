// Flat ESLint config for @h82/mxm4-haptic (per-package, as the workspace uses
// per-member lint configs). ESLint does the LINTING; Prettier owns FORMATTING.
// eslint-config-prettier is appended last to switch off every ESLint rule that
// would fight Prettier, so the two never disagree on style.
import { defineConfig } from "eslint/config";
import js from "@eslint/js";
import tseslint from "typescript-eslint";
import eslintConfigPrettier from "eslint-config-prettier/flat";
import { fileURLToPath, URL } from "node:url";

const __dirname = fileURLToPath(new URL(".", import.meta.url));

export default defineConfig(
  { ignores: ["dist/**", ".turbo/**"] },
  js.configs.recommended,
  tseslint.configs.recommended,
  {
    // Pin the project-service root for EVERY file the TS parser touches. The
    // `recommended` config applies that parser globally — including to this
    // flat-config file — so without a root set here, typescript-eslint tries to
    // infer one from the call stack and errors with "multiple candidate
    // TSConfigRootDirs" when an editor lints from the workspace root (where both
    // members' `eslint.config.mjs` are visible).
    languageOptions: {
      parserOptions: {
        tsconfigRootDir: __dirname,
      },
    },
  },
  {
    // Enable type-aware parsing through the TypeScript project service only for
    // source `.ts` files, so out-of-project files (this config, tests not in
    // tsconfig's `include`) aren't required to belong to a tsconfig — `eslint .`
    // would otherwise error on them.
    files: ["src/**/*.ts"],
    languageOptions: {
      parserOptions: {
        projectService: true,
      },
    },
  },
  {
    rules: {
      // Allow intentionally-unused identifiers when prefixed with `_`.
      "@typescript-eslint/no-unused-vars": [
        "error",
        {
          argsIgnorePattern: "^_",
          varsIgnorePattern: "^_",
          caughtErrorsIgnorePattern: "^_",
        },
      ],
    },
  },
  eslintConfigPrettier,
);
