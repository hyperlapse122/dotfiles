#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
scratch_root="${XDG_RUNTIME_DIR:-$HOME/.cache}/agent-scratch"
mkdir -p "$scratch_root"
scratch=$(mktemp -d "$scratch_root/package-ownership.XXXXXX")
trap 'rm -rf -- "$scratch"' EXIT
printf '[data]\n' >"$scratch/empty.toml"

inventory_json() {
  printf '%s' '{{ .packages.authority.capabilities | toJson }}' |
    chezmoi --config "$scratch/empty.toml" --source "$1" execute-template
}
make_fixture() {
  local root=$1
  mkdir -p "$root/dot_config/mise" "$root/packages/release-lock/src"
  cp -a "$repo_root/.chezmoidata" "$repo_root/.chezmoitemplates" "$repo_root/.chezmoiexternals" "$root/"
  cp -a "$repo_root/dot_config/mise/config.toml" "$root/dot_config/mise/"
  cp -a "$repo_root/packages/release-lock/src/registry.ts" "$root/packages/release-lock/src/"
}

check_root() {
  local root=$1
  inventory_json "$root" >"$scratch/inventory.json"
  node - "$root" "$scratch/inventory.json" <<'JS'
const fs = require("node:fs");
const path = require("node:path");
const [root, inventoryPath] = process.argv.slice(2);
const read = relative => fs.readFileSync(path.join(root, relative), "utf8").replace(/\r\n/g, "\n");
const capabilities = JSON.parse(fs.readFileSync(inventoryPath, "utf8"));
const packages = read(".chezmoidata/packages.yaml");
const miseText = read("dot_config/mise/config.toml");
const toolsBody = miseText.split("[tools]\n", 2)[1]?.split("\n[settings]", 1)[0] ?? "";
const miseNames = new Set(
  [...toolsBody.matchAll(/^(?:"([^"]+)"|([A-Za-z0-9_-]+))\s*=/gm)]
    .map(match => (match[1] ?? match[2]).split(":").at(-1)),
);
const registryText = read("packages/release-lock/src/registry.ts");
const registry = new Set(
  [...registryText.matchAll(/^  (?:"([A-Za-z0-9-]+)"|([A-Za-z][A-Za-z0-9-]*)): \{/gm)]
    .map(match => match[1] ?? match[2]),
);
const externalText = fs.readdirSync(path.join(root, ".chezmoiexternals"))
  .filter(name => name.endsWith(".toml"))
  .map(name => read(path.join(".chezmoiexternals", name)))
  .join("\n");
const externals = new Set([...externalText.matchAll(/^\[([A-Za-z0-9-]+)\]$/gm)].map(match => match[1]));
const escapeRegExp = value => value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
const presentInLegacy = identifier =>
  new RegExp(`^\\s+-\\s+${escapeRegExp(identifier)}(?:\\s+#.*)?$`, "m").test(packages);
const fail = message => {
  console.error(`package ownership: ${message}`);
  process.exit(1);
};

const sentinels = new Map();
for (const capability of capabilities) {
  const sentinel = capability.sentinel;
  if (sentinel) {
    if (sentinels.has(sentinel)) {
      fail(`duplicate PATH sentinel ${JSON.stringify(sentinel)}: ${sentinels.get(sentinel)} and ${capability.id}`);
    }
    sentinels.set(sentinel, capability.id);
  }
  const fedora = capability.fedora;
  if (fedora.disposition !== "managed") continue;
  const { owner, identifier } = fedora;
  if (sentinel && owner !== "mise" && miseNames.has(sentinel)) {
    fail(`${capability.id} has both native and alternate owner for PATH sentinel ${sentinel}`);
  }
  if (sentinel && !["external", "releaseLock"].includes(owner) && externals.has(sentinel)) {
    fail(`${capability.id} has both native and alternate owner for PATH sentinel ${sentinel}`);
  }
  if (owner === "mise") {
    if (!miseNames.has(identifier)) fail(`${capability.id} says mise owns ${identifier}, but mise does not declare it`);
    if (presentInLegacy(identifier)) fail(`${identifier} is duplicated between mise and the Fedora package manifest`);
  } else if (["external", "releaseLock"].includes(owner)) {
    if (!registry.has(identifier) && !externals.has(identifier)) {
      fail(`${capability.id} has no release-lock/external declaration for ${identifier}`);
    }
    if (presentInLegacy(identifier)) {
      fail(`${identifier} is duplicated between native packages and release-lock/externals`);
    }
  } else if (!["dnf", "flatpak", "dotnet", "directRpm"].includes(owner)) {
    fail(`${capability.id} uses unsupported Fedora owner ${owner}`);
  }
}

if (!registry.has("gh") || !externals.has("gh") || presentInLegacy("gh")) {
  fail("gh must be one locked external chain and absent from Fedora native packages");
}
if (!registry.has("kitty") || presentInLegacy("kitty")) {
  fail("kitty must be release-lock owned and absent from Fedora native packages");
}
if (!miseNames.has("kdotool") || presentInLegacy("kdotool")) {
  fail("kdotool must be mise owned and absent from Fedora native packages");
}
if (!registry.has("codex") || !externals.has("codex") || miseNames.has("codex")) {
  fail("codex must be one locked external chain and absent from mise");
}
JS
}

check_root "$repo_root"
fixture="$scratch/duplicate-owner"
make_fixture "$fixture"
node - "$fixture/dot_config/mise/config.toml" <<'JS'
const fs = require("node:fs");
const path = process.argv[2];
const text = fs.readFileSync(path, "utf8").replace(/\r\n/g, "\n");
const temporaryPath = `${path}.fixture`;
fs.writeFileSync(temporaryPath, text.replace("[tools]\n", '[tools]\ngh = "latest"\n'));
fs.renameSync(temporaryPath, path);
JS
if check_root "$fixture" >"$scratch/duplicate.out" 2>"$scratch/duplicate.err"; then
  printf '%s\n' 'package ownership: duplicate owner fixture was accepted' >&2
  exit 1
fi
grep -F 'alternate owner for PATH sentinel gh' "$scratch/duplicate.err" >/dev/null || {
  cat "$scratch/duplicate.err" >&2
  exit 1
}

printf '%s\n' 'package ownership validation passed'
