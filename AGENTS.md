# AGENTS.md

Follow repo rules in `.github/copilot-instructions.md` (keep changes small + idempotent; edit user-facing configs in place; treat `dotbot/` as vendored).
Cursor rules: none found (`.cursorrules` / `.cursor/rules/`).

Dotfiles install/verify (repo root):
- Fresh machine: `./bootstrap.sh`
- Re-run after changes: `./install.sh` (internally runs `mise exec -- sh ./install` and `mise exec -- sudo sh ./install-root`)

Dotbot (vendored) dev loop (run from `dotbot/`):
- Tests: `hatch test`
- Single test: `hatch test tests/test_shell.py::test_shell_can_override_defaults`
- Lint/format (Ruff): `hatch fmt` (fix) / `hatch fmt --check` (CI-style)
- Types (mypy strict): `hatch run types:check`
- Build artifacts: `hatch build`

Style guidelines:
- Avoid sweeping reformatting; don’t edit vendored deps (`dotbot/lib/`, e.g. `pyyaml`) unless required.
- YAML/install configs: preserve idempotency (defaults like `create/relink/force`), keep paths repo-relative, guard OS-specific actions with `if: '[ `uname` = ... ]'`.
- Python (`dotbot/`): keep full type hints, stdlib→third-party→local imports, raise specific exceptions (`raise X from e`), prefer project messaging/logging over `print`.
- Formatting baseline (from `dotbot/.editorconfig`): UTF-8, LF, final newline, trim trailing whitespace; Python indent=4.
