#!/usr/bin/env bash
set -euo pipefail

usage='usage: test-omp-real-plugin.sh HAPTIC_PACKAGE'
haptic_package=${1:?$usage}
repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
locked_version=$(jq -er '.releases.tools.omp.version | sub("^v"; "")' "$repo_root/.chezmoidata/releases.json")
command -v omp >/dev/null 2>&1 || { printf 'locked omp binary is not on PATH\n' >&2; exit 1; }
command -v bun >/dev/null 2>&1 || { printf 'bun is not on PATH\n' >&2; exit 1; }
[[ -f $haptic_package/package.json && -f $haptic_package/dist/index.js ]] || {
  printf 'haptic package is incomplete: %s\n' "$haptic_package" >&2
  exit 1
}
version_pattern=${locked_version//./\\.}
[[ $(omp --version) =~ (^|[^[:digit:]])${version_pattern}([^[:digit:]]|$) ]] || {
  printf 'omp on PATH does not match locked version %s\n' "$locked_version" >&2
  exit 1
}

scratch_root=${XDG_RUNTIME_DIR:-"$HOME/.cache"}/omp-real-plugin
mkdir -p -- "$scratch_root"
chmod 0700 -- "$scratch_root"
scratch=$(mktemp -d "$scratch_root/smoke.XXXXXX")
trap 'rm -rf -- "$scratch"' EXIT
home="$scratch/home"
marketplace="$scratch/marketplace"
mkdir -p "$home" "$marketplace/.omp-plugin" "$marketplace/plugins"
cp -R -- "$haptic_package" "$marketplace/plugins/mxm4-haptic"
cat >"$marketplace/.omp-plugin/marketplace.json" <<'JSON'
{"name":"h82-dotfiles","owner":{"name":"test"},"plugins":[{"name":"mxm4-haptic","source":"./plugins/mxm4-haptic"}]}
JSON

run_omp() {
  env -u PI_CODING_AGENT_DIR -u OMP_AGENT_ENV \
    HOME="$home" USERPROFILE="$home" XDG_CONFIG_HOME="$home/.config" XDG_DATA_HOME="$home/.local/share" \
    omp "$@"
}

run_omp plugin marketplace add "$marketplace"
run_omp plugin install --scope user --force mxm4-haptic@h82-dotfiles
run_omp plugin enable --scope user mxm4-haptic@h82-dotfiles
run_omp plugin list >"$scratch/list.out"
run_omp plugin doctor >"$scratch/doctor.out"
grep -F 'mxm4-haptic' "$scratch/list.out" >/dev/null
grep -F 'h82-dotfiles' "$scratch/list.out" >/dev/null

installed="$home/.omp/plugins/installed_plugins.json"
lock="$home/.omp/plugins/omp-plugins.lock.json"
jq -e '
  .plugins["mxm4-haptic@h82-dotfiles"] as $rows
  | ($rows | type) == "array"
    and ($rows | length) == 1
    and $rows[0].scope == "user"
    and ($rows[0].installPath | type) == "string"
' "$installed" >/dev/null
jq -e '.plugins["@h82/omp-mxm4-haptic"].enabled == true' "$lock" >/dev/null
install_root=$(jq -er '.plugins["mxm4-haptic@h82-dotfiles"][0].installPath' "$installed")
case $install_root in
  "$home"/*) ;;
  *) printf 'installed plugin escaped relocated HOME: %s\n' "$install_root" >&2; exit 1 ;;
esac

loader="$scratch/fresh-loader.ts"
cat >"$loader" <<'BUN'
import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import { pathToFileURL } from "node:url";

const root = process.argv[2];
const parsed = JSON.parse(await readFile(resolve(root, "package.json"), "utf8")) as unknown;
if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) {
  throw new Error("package manifest is not an object");
}
const manifest = parsed as Record<string, unknown>;
const omp = manifest.omp;
if (typeof omp !== "object" || omp === null || Array.isArray(omp)) {
  throw new Error("package manifest has no omp metadata");
}
const extensions = (omp as Record<string, unknown>).extensions;
if (!Array.isArray(extensions) || extensions.length !== 1 || extensions[0] !== "./dist/index.js") {
  throw new Error("package does not expose one canonical extension");
}
const entry = resolve(root, extensions[0]);
const loaded = await import(`${pathToFileURL(entry).href}?fresh=${Date.now()}`);
if (typeof loaded.default !== "function") throw new Error("default export is not a factory");
const handlers = new Map<string, unknown[]>();
const api = new Proxy(
  {
    on(event: string, handler: unknown) {
      const values = handlers.get(event) ?? [];
      values.push(handler);
      handlers.set(event, values);
    },
  },
  {
    get(target, property) {
      if (property in target) return Reflect.get(target, property);
      return () => { throw new Error(`unexpected loader registration ${String(property)}`); };
    },
  },
);
await loaded.default(api);
const actual = [...handlers.entries()].flatMap(([event, values]) => values.map(() => event)).sort();
const expected = ["after_provider_response", "agent_end", "agent_start", "tool_call"];
if (JSON.stringify(actual) !== JSON.stringify(expected)) {
  throw new Error(`expected one haptic owner, got ${actual.join(",")}`);
}
BUN
bun "$loader" "$install_root"

printf 'real OMP marketplace, list, doctor, canonical state, and fresh loader smoke passed\n'
