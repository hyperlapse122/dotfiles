// Flat ESLint config for @h82/opencode-mxm4-haptic (per-package, as the
// workspace uses per-member lint configs). ESLint does the LINTING; Prettier
// owns FORMATTING. eslint-config-prettier is appended last to switch off every
// ESLint rule that would fight Prettier, so the two never disagree on style.
import js from "@eslint/js";
import tseslint from "typescript-eslint";
import eslintConfigPrettier from "eslint-config-prettier/flat";

export default tseslint.config(
  { ignores: ["dist/**", ".turbo/**"] },
  js.configs.recommended,
  tseslint.configs.recommended,
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
