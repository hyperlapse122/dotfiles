# Lifecycle-script override mechanics — reference

Opt in at the **narrowest possible scope**:

| Manager | Scope | Mechanism |
|---|---|---|
| **Yarn Berry** *(preferred — primary manager in this dotfiles policy)* | **per-package** | `dependenciesMeta.<pkg>.built: true` in project `package.json`. Only that package's install/build scripts run; everything else stays blocked. |
| **npm** | **per-repository** | `ignore-scripts=false` in a committed project `.npmrc`. npm has no per-package override; `dependenciesMeta` is not recognised. |
| **pnpm** | **per-repository** | Add to `allowBuilds` (pnpm v11+) or `onlyBuiltDependencies` (v10 and earlier) in `pnpm-workspace.yaml`. **MUST NOT** rely on `dependenciesMeta.<pkg>.built` — pnpm silently ignores it. |
| **Bun** | **per-repository** | Add the package name to `trustedDependencies` in project `package.json`. |

**MUST** name the specific install-time behaviour being unblocked (native binding, codegen,
asset fetch, etc.) in the PR/MR description or as a code comment next to the override. "It
failed without this" is not sufficient justification.
