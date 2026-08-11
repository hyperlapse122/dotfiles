#!/usr/bin/env bash
set -euo pipefail

usage='usage: test-omp-agent-reconcile.sh AUTH_SCRIPT PLUGIN_SCRIPT HAPTIC_PACKAGE SETTINGS_SH'
auth_script=${1:?$usage}
plugin_script=${2:?$usage}
haptic_package=${3:?$usage}
settings_script=${4:?$usage}
repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
locked_omp_version=$(jq -er '.releases.tools.omp.version | sub("^v"; "")' "$repo_root/.chezmoidata/releases.json")
scratch_root=${XDG_RUNTIME_DIR:-"$HOME/.cache"}/omp-agent-reconcile-fixtures
mkdir -p -- "$scratch_root"
chmod 0700 -- "$scratch_root"
scratch=$(mktemp -d "$scratch_root/run.XXXXXX")
cleanup() {
  rm -rf -- "$scratch"
}
trap cleanup EXIT

home="$scratch/home"
fake_bin="$scratch/bin"
mkdir -p "$home/.omp/agent" "$fake_bin"

# One managed variable per reconcile property: EXA twice (collapse duplicates),
# OPENROUTER once (overwrite a single stale value), OPENCODE absent (insert when
# missing). Keep all three shapes represented whenever the managed set changes —
# the per-name `-eq 1` counts below are what turn each shape into an assertion.
cat >"$home/.omp/agent/.env" <<'EOF'
# user-owned values stay byte-identical
OTHER_TOKEN='keep me'
EXA_API_KEY=stale
EXA_API_KEY="duplicate"
OPENROUTER_API_KEY=stale
EOF
chmod 0644 "$home/.omp/agent/.env"

auth="$home/.omp/agent/.env"
run_auth() {
  env HOME="$home" OMP_AGENT_ENV="$auth" bash "$auth_script"
}
run_auth

[[ $(stat -c '%a' "$auth") == 600 ]]
[[ $(grep -c '^EXA_API_KEY=' "$auth") -eq 1 ]]
[[ $(grep -c '^OPENROUTER_API_KEY=' "$auth") -eq 1 ]]
[[ $(grep -c '^OPENCODE_API_KEY=' "$auth") -eq 1 ]]
grep -F "# user-owned values stay byte-identical" "$auth" >/dev/null
grep -F "OTHER_TOKEN='keep me'" "$auth" >/dev/null
grep -F 'EXA_API_KEY="dummy-secret"' "$auth" >/dev/null
grep -F 'OPENROUTER_API_KEY="openrouter-test-secret"' "$auth" >/dev/null
grep -F 'OPENCODE_API_KEY="opencode-test-secret"' "$auth" >/dev/null
ambient="$scratch/ambient.env"
printf 'AMBIENT_TOKEN=keep\n' >"$ambient"
OMP_AGENT_ENV="$ambient" run_auth
[[ $(cat "$ambient") == 'AMBIENT_TOKEN=keep' ]]

# The rendered POSIX script must enforce the ordered managed set.
expected_names="$scratch/expected-managed-names"
printf '%s\n' EXA_API_KEY OPENROUTER_API_KEY OPENCODE_API_KEY >"$expected_names"
posix_names="$scratch/posix-managed-names"
grep -m1 '^MANAGED_NAMES=' "$auth_script" |
  grep -oE '"[A-Z0-9_]+"' | tr -d '"' >"$posix_names"
diff -u "$expected_names" "$posix_names"

printf 'NOT A DOTENV ASSIGNMENT\n' >"$auth"
if run_auth >"$scratch/malformed.out" 2>"$scratch/malformed.err"; then
  printf 'auth reconcile accepted malformed dotenv input\n' >&2
  exit 1
fi
[[ $(cat "$auth") == 'NOT A DOTENV ASSIGNMENT' ]]
grep -F 'refusing malformed dotenv line' "$scratch/malformed.err" >/dev/null

referent="$scratch/referent"
printf 'do not overwrite\n' >"$referent"
rm "$auth"
ln -s "$referent" "$auth"
if run_auth >"$scratch/auth.out" 2>"$scratch/auth.err"; then
  printf 'auth reconcile accepted a symlink target\n' >&2
  exit 1
fi
[[ $(cat "$referent") == 'do not overwrite' ]]
grep -F 'unsafe target' "$scratch/auth.err" >/dev/null

# The rendered POSIX script must carry the data rows, fail-closed lifecycle
# calls, digest/loader checks, migration boundary, locked OMP version, and
# raw-input fingerprint set.
for needle in \
  'mxm4-haptic@h82-dotfiles' \
  'compound-engineering' \
  'plugin marketplace add' \
  'plugin install --scope user --force' \
  'plugin enable --scope user' \
  'payload digest' \
  'loader health' \
  'legacy'; do
  grep -F "$needle" "$plugin_script" >/dev/null
done
grep -F "readonly EXPECTED_OMP_VERSION='$locked_omp_version'" "$plugin_script" >/dev/null
posix_fingerprints="$scratch/posix-plugin-fingerprints"
grep '^#   ' "$plugin_script" >"$posix_fingerprints"
[[ -s $posix_fingerprints ]]
for raw_input in \
  '.chezmoidata/agents.yaml' \
  '.chezmoidata/haptic.yaml' \
  '.chezmoidata/releases.json' \
  'packages/bun.lock' \
  '.chezmoiscripts/70-agents/run_after_patch-i-have-adhd-extension.sh.tmpl' \
  'packages/mxm4-haptic/src/omp-plugin.ts'; do
  grep -F "#   $raw_input  " "$posix_fingerprints" >/dev/null
done
[[ -f $haptic_package/package.json && -f $haptic_package/dist/index.js ]]
source="$home/.local/share/omp-plugins"
mkdir -p "$source/.omp-plugin" "$source/plugins" "$home/.local/share/compound-engineering/v-test/.claude-plugin"
cp -R "$haptic_package" "$source/plugins/mxm4-haptic"
cat >"$source/.omp-plugin/marketplace.json" <<'EOF'
{"name":"h82-dotfiles","owner":{"name":"test"},"plugins":[{"name":"mxm4-haptic","source":"./plugins/mxm4-haptic"}]}
EOF
cat >"$home/.local/share/compound-engineering/v-test/.claude-plugin/marketplace.json" <<'EOF'
{"name":"compound-engineering-plugin","plugins":[{"name":"compound-engineering","source":"./"}]}
EOF
adhd="$home/.local/share/i-have-adhd/test-sha"
mkdir -p "$adhd/.claude-plugin" "$adhd/extensions" "$adhd/skills/i-have-adhd"
cat >"$adhd/.claude-plugin/marketplace.json" <<'EOF'
{"name":"i-have-adhd","plugins":[{"name":"i-have-adhd","source":"./"}]}
EOF
printf 'extension loader\n' >"$adhd/extensions/i-have-adhd.ts"
printf 'ruleset\n' >"$adhd/skills/i-have-adhd/SKILL.md"
cat >"$adhd/package.json" <<'EOF'
{"name":"i-have-adhd","pi":{"extensions":["./extensions/i-have-adhd.ts"],"skills":["./skills"]}}
EOF

# Rendered local paths are immutable desired state. Relocate them into the
# isolated HOME without letting the provisioner consult the live HOME.
test_plugin="$scratch/plugins.sh"
cp "$plugin_script" "$test_plugin"
haptic_row=$(grep -m1 'mxm4-haptic\\th82-dotfiles\\tlocalDir\\t' "$test_plugin")
rendered_haptic=${haptic_row#*localDir\\t}
rendered_haptic=${rendered_haptic%%\\t*}
ce_row=$(grep -m1 'compound-engineering\\tcompound-engineering-plugin\\tlocalArchive\\t' "$test_plugin")
rendered_ce=${ce_row#*localArchive\\t}
rendered_ce=${rendered_ce%%\\t*}
adhd_row=$(grep -m1 'i-have-adhd\\ti-have-adhd\\tlocalArchive\\t' "$test_plugin")
rendered_adhd=${adhd_row#*localArchive\\t}
rendered_adhd=${rendered_adhd%%\\t*}
sed -i "s|$rendered_haptic|$source|g; s|$rendered_ce|$home/.local/share/compound-engineering/v-test|g; s|$rendered_adhd|$adhd|g" "$test_plugin"
chmod 0700 "$test_plugin"

# The stub answers --version in the real binary's omp/<version> format so the
# reconciler's preflight is tested against reality, not a shape omp never prints.
# OMP_STUB_VERSION replaces the whole emitted string for reject coverage.
cat >"$fake_bin/omp" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$OMP_CALLS"
[[ ${1-} == --version ]] && { printf '%s\n' "${OMP_STUB_VERSION:-omp/${EXPECTED_OMP_VERSION:?}}"; exit 0; }
if [[ -n ${OMP_FAIL_MATCH:-} && "$*" == *"$OMP_FAIL_MATCH"* ]]; then exit 72; fi
root="$HOME/.omp/plugins"
mkdir -p "$root"
case "$*" in
  "plugin marketplace add "*/omp-plugins) printf '%s\n' "${*:4}" >"$HOME/.haptic-source" ;;
  "plugin install --scope user --force mxm4-haptic@h82-dotfiles")
    source=$(cat "$HOME/.haptic-source")
    install="$root/cache/plugins/h82-dotfiles___mxm4-haptic___0.0.0"
    rm -rf "$install"; mkdir -p "$(dirname "$install")"; cp -R "$source/plugins/mxm4-haptic" "$install"
    mkdir -p "$root/node_modules/@h82"; ln -sfn "$install" "$root/node_modules/@h82/omp-mxm4-haptic"
    cat >"$root/installed_plugins.json" <<JSON
{"version":2,"plugins":{"mxm4-haptic@h82-dotfiles":[{"scope":"user","installPath":"$install","version":"0.0.0"}]}}
JSON
    ;;
  "plugin enable --scope user mxm4-haptic@h82-dotfiles")
    printf '%s\n' '{"plugins":{"@h82/omp-mxm4-haptic":{"version":"0.0.0","enabled":true}},"settings":{}}' >"$root/omp-plugins.lock.json"
    ;;
esac
EOF
chmod 0755 "$fake_bin/omp"

run_plugins() {
  OMP_CALLS="$1" OMP_FAIL_MATCH="${2-}" OMP_STUB_VERSION="${3-}" EXPECTED_OMP_VERSION="$locked_omp_version" \
    env HOME="$home" PATH="$fake_bin:$PATH" bash "$test_plugin"
}
legacy="$home/.omp/agent/extensions/mxm4-haptic.ts"
mkdir -p "$(dirname "$legacy")"
printf 'legacy owner\n' >"$legacy"
if run_plugins "$scratch/fail.calls" 'plugin enable --scope user mxm4-haptic@h82-dotfiles' >"$scratch/fail.out" 2>"$scratch/fail.err"; then
  printf 'injected enable failure unexpectedly succeeded\n' >&2
  exit 1
fi
[[ -f $legacy ]]

# The version gate rejects mismatched, digit-adjacent, and suffixed decoys
# before any marketplace mutation, and still accepts the bare version form.
for decoy in "omp/0.0.0" "omp/9$locked_omp_version" "omp/$locked_omp_version-rc.1" "omp/${locked_omp_version}9"; do
  label=${decoy//[^a-z0-9]/-}
  if run_plugins "$scratch/version$label.calls" '' "$decoy" >"$scratch/version$label.out" 2>"$scratch/version$label.err"; then
    printf 'version decoy %s unexpectedly passed preflight\n' "$decoy" >&2
    exit 1
  fi
  grep -F 'preflight: expected omp' "$scratch/version$label.err" >/dev/null
  if grep -qF 'plugin marketplace add' "$scratch/version$label.calls"; then
    printf 'version decoy %s reached marketplace mutation\n' "$decoy" >&2
    exit 1
  fi
done
run_plugins "$scratch/version-bare.calls" '' "$locked_omp_version"
# The bare-accept run is a full reconcile and removes the legacy sentinel;
# recreate it so the success runs below still prove their own removal.
printf 'legacy owner\n' >"$legacy"

run_plugins "$scratch/omp.calls"
[[ ! -e $legacy ]]
run_plugins "$scratch/repeat.calls"
[[ ! -e $legacy ]]
[[ $(grep -c 'plugin install --scope user --force mxm4-haptic@h82-dotfiles' "$scratch/repeat.calls") -eq 1 ]]
[[ $(grep -c 'plugin enable --scope user mxm4-haptic@h82-dotfiles' "$scratch/repeat.calls") -eq 1 ]]
grep -F 'plugin install --scope user --force compound-engineering@compound-engineering-plugin' "$scratch/omp.calls" >/dev/null
grep -F 'plugin enable --scope user compound-engineering@compound-engineering-plugin' "$scratch/omp.calls" >/dev/null
grep -F 'plugin install --scope user --force i-have-adhd@i-have-adhd' "$scratch/omp.calls" >/dev/null
grep -F 'plugin enable --scope user i-have-adhd@i-have-adhd' "$scratch/omp.calls" >/dev/null
grep -F "plugin marketplace add $adhd" "$scratch/omp.calls" >/dev/null

# A removed required path fails the run before any marketplace mutation.
mv "$adhd/extensions/i-have-adhd.ts" "$adhd/extensions/i-have-adhd.ts.off"
if run_plugins "$scratch/adhd-path.calls" >"$scratch/adhd-path.out" 2>"$scratch/adhd-path.err"; then
  printf 'missing i-have-adhd required path unexpectedly succeeded\n' >&2
  exit 1
fi
mv "$adhd/extensions/i-have-adhd.ts.off" "$adhd/extensions/i-have-adhd.ts"
grep -F 'preflight: required path is missing' "$scratch/adhd-path.err" >/dev/null
if grep -qF 'plugin marketplace add' "$scratch/adhd-path.calls"; then
  printf 'missing required path reached marketplace mutation\n' >&2
  exit 1
fi

expect_adhd_manifest_drift() {
  local label=$1
  local manifest=$2
  printf '%s\n' "$manifest" >"$adhd/package.json"
  if run_plugins "$scratch/adhd-$label.calls" >"$scratch/adhd-$label.out" 2>"$scratch/adhd-$label.err"; then
    printf 'drifted i-have-adhd pi manifest %s unexpectedly succeeded\n' "$label" >&2
    exit 1
  fi
  grep -F 'preflight: pi manifest drift' "$scratch/adhd-$label.err" >/dev/null
  if grep -qF 'plugin marketplace add' "$scratch/adhd-$label.calls"; then
    printf 'pi manifest drift %s reached marketplace mutation\n' "$label" >&2
    exit 1
  fi
}

expect_adhd_manifest_drift extra-extension \
  '{"name":"i-have-adhd","pi":{"extensions":["./extensions/i-have-adhd.ts","./extensions/sneaky.ts"],"skills":["./skills"]}}'
expect_adhd_manifest_drift missing-extension \
  '{"name":"i-have-adhd","pi":{"extensions":[],"skills":["./skills"]}}'
expect_adhd_manifest_drift broad-extension \
  '{"name":"i-have-adhd","pi":{"extensions":["./extensions"],"skills":["./skills"]}}'
expect_adhd_manifest_drift swapped-kinds \
  '{"name":"i-have-adhd","pi":{"extensions":["./skills"],"skills":["./extensions/i-have-adhd.ts"]}}'
cat >"$adhd/package.json" <<'EOF'
{"name":"i-have-adhd","pi":{"extensions":["./extensions/i-have-adhd.ts"],"skills":["./skills"]}}
EOF

expect_adhd_marketplace_drift() {
  local label=$1
  local catalog=$2
  printf '%s\n' "$catalog" >"$adhd/.claude-plugin/marketplace.json"
  if run_plugins "$scratch/adhd-catalog-$label.calls" >"$scratch/adhd-catalog-$label.out" 2>"$scratch/adhd-catalog-$label.err"; then
    printf 'drifted i-have-adhd marketplace %s unexpectedly succeeded\n' "$label" >&2
    exit 1
  fi
  grep -F 'preflight: marketplace manifest drift' "$scratch/adhd-catalog-$label.err" >/dev/null
  if grep -qF 'plugin marketplace add' "$scratch/adhd-catalog-$label.calls"; then
    printf 'marketplace drift %s reached mutation\n' "$label" >&2
    exit 1
  fi
}

expect_adhd_marketplace_drift renamed \
  '{"name":"renamed","plugins":[{"name":"i-have-adhd","source":"./"}]}'
expect_adhd_marketplace_drift source \
  '{"name":"i-have-adhd","plugins":[{"name":"i-have-adhd","source":"./elsewhere"}]}'
cat >"$adhd/.claude-plugin/marketplace.json" <<'EOF'
{"name":"i-have-adhd","plugins":[{"name":"i-have-adhd","source":"./"}]}
EOF
mv "$home/.local/share/compound-engineering/v-test/.claude-plugin/marketplace.json" \
  "$home/.local/share/compound-engineering/v-test/.claude-plugin/marketplace.json.off"
if run_plugins "$scratch/ce-manifest.calls" >"$scratch/ce-manifest.out" 2>"$scratch/ce-manifest.err"; then
  printf 'missing compound-engineering manifest unexpectedly succeeded\n' >&2
  exit 1
fi
mv "$home/.local/share/compound-engineering/v-test/.claude-plugin/marketplace.json.off" \
  "$home/.local/share/compound-engineering/v-test/.claude-plugin/marketplace.json"
grep -F 'preflight: pinned marketplace is missing' "$scratch/ce-manifest.err" >/dev/null
if grep -qF 'plugin marketplace add' "$scratch/ce-manifest.calls"; then
  printf 'missing CE manifest reached marketplace mutation\n' >&2
  exit 1
fi

# i-have-adhd patch: render, convergence, handler behavior, and drift
printf '#!/usr/bin/env bash\ncase "${1-}" in whoami) printf dummy@example.invalid;; *) printf dummy-secret;; esac\n' >"$fake_bin/op"
chmod 0755 "$fake_bin/op"
patch_config="$scratch/patch-empty.toml"
: >"$patch_config"
patch_script="$scratch/patch-i-have-adhd.sh"
env PATH="$fake_bin:$PATH" chezmoi \
  --config "$patch_config" \
  --source "$repo_root" \
  execute-template \
  < "$repo_root/.chezmoiscripts/70-agents/run_after_patch-i-have-adhd-extension.sh.tmpl" \
  > "$patch_script"
adhd_tree="$scratch/adhd-pinned-tree"
mkdir -p "$adhd_tree/extensions"
sed -i "s|^TREE=.*|TREE=\"$adhd_tree\"|" "$patch_script"
loader="$adhd_tree/extensions/i-have-adhd.ts"
fixture_prefix="$scratch/loader.prefix"
fixture_upstream="$scratch/loader.upstream"
fixture_patched="$scratch/loader.patched-function"
fixture_suffix="$scratch/loader.suffix"
cat >"$fixture_prefix" <<'EOF'
type ExtensionAPI = any;
type ExtensionContext = any;
type AdhdModeState = { enabled: boolean };

const existsSync = () => false;
const getAgentDir = () => "/tmp";
const join = (...parts: string[]) => parts.join("/");
const STATE_ENTRY_TYPE = "i-have-adhd-state";
const RULES_MESSAGE_TYPE = "i-have-adhd-rules";
const DISABLED_MESSAGE_TYPE = "i-have-adhd-disabled";
const STATUS_KEY = "i-have-adhd";
const RULES_HEADER = "ADHD MODE ACTIVE.";
const DISABLED_NOTICE = "ADHD MODE OFF.";

function loadRules(): string {
  return "fixture rules";
}

function getSavedState(ctx: ExtensionContext): boolean | undefined {
  let savedState: boolean | undefined;

  for (const entry of ctx.sessionManager.getBranch()) {
    if (entry.type !== "custom" || entry.customType !== STATE_ENTRY_TYPE) {
      continue;
    }

    const data = entry.data as Partial<AdhdModeState> | undefined;
    if (typeof data?.enabled === "boolean") {
      savedState = data.enabled;
    }
  }

  return savedState;
}
EOF
cat >"$fixture_upstream" <<'EOF'
function rulesAreInContext(ctx: ExtensionContext): boolean {
  let active = false;

  for (const entry of ctx.sessionManager.buildContextEntries()) {
    if (entry.type !== "custom_message") continue;

    if (entry.customType === RULES_MESSAGE_TYPE) {
      active = true;
    } else if (entry.customType === DISABLED_MESSAGE_TYPE) {
      active = false;
    }
  }

  return active;
}
EOF
cat >"$fixture_patched" <<'EOF'
function rulesAreInContext(ctx: ExtensionContext): boolean {
  let active = false;
  const contextEntries =
    ctx.sessionManager.buildContextEntries?.() ??
    ctx.sessionManager.buildSessionContext().messages;

  for (const entry of contextEntries) {
    if (
      !("customType" in entry) ||
      ("type" in entry && entry.type !== "custom_message") ||
      ("role" in entry && entry.role !== "custom")
    ) {
      continue;
    }

    if (entry.customType === RULES_MESSAGE_TYPE) {
      active = true;
    } else if (entry.customType === DISABLED_MESSAGE_TYPE) {
      active = false;
    }
  }

  return active;
}
EOF
cat >"$fixture_suffix" <<'EOF'
export default function iHaveAdhdExtension(pi: ExtensionAPI) {
  const rules = loadRules();
  const alwaysOnFlag = join(getAgentDir(), ".i-have-adhd-always");
  let enabled = false;

  const updateStatus = (ctx: ExtensionContext): void => {
    if (!enabled) {
      ctx.ui.setStatus(STATUS_KEY, undefined);
      return;
    }

    const dot = ctx.ui.theme.fg("success", "●");
    const label = ctx.ui.theme.fg("accent", "ADHD ON");
    ctx.ui.setStatus(STATUS_KEY, `${dot} ${label}`);
  };

  const syncContext = (ctx: ExtensionContext): void => {
    const injected = rulesAreInContext(ctx);

    if (enabled && !injected) {
      pi.sendMessage(
        {
          customType: RULES_MESSAGE_TYPE,
          content: `${RULES_HEADER}\n\n${rules}`,
          display: false,
        },
        { triggerTurn: false },
      );
      return;
    }

    if (!enabled && injected) {
      pi.sendMessage(
        {
          customType: DISABLED_MESSAGE_TYPE,
          content: DISABLED_NOTICE,
          display: false,
        },
        { triggerTurn: false },
      );
    }
  };

  const restoreState = (ctx: ExtensionContext): void => {
    const savedState = getSavedState(ctx);
    const enabledByDefault =
      pi.getFlag("adhd") === true || existsSync(alwaysOnFlag);

    enabled = savedState ?? enabledByDefault;
    updateStatus(ctx);
    syncContext(ctx);
  };

  pi.registerFlag("adhd", {
    description: "Start with ADHD-friendly output enabled",
    type: "boolean",
    default: false,
  });
  pi.on("session_start", async (_event, ctx) => restoreState(ctx));
  pi.on("session_compact", async (_event, ctx) => syncContext(ctx));
}
EOF
cat "$fixture_prefix" "$fixture_upstream" "$fixture_suffix" >"$loader"
cat "$fixture_prefix" "$fixture_patched" "$fixture_suffix" >"$scratch/loader.patched"
env HOME="$home" bash "$patch_script"
cmp -s "$scratch/loader.patched" "$loader" || { echo 'first patch run did not produce the expected loader' >&2; exit 1; }
env HOME="$home" bash "$patch_script"
cmp -s "$scratch/loader.patched" "$loader" || { echo 'second patch run was not a no-op' >&2; exit 1; }
cat >"$scratch/test-adhd-compaction.mjs" <<'EOF'
import { pathToFileURL } from "node:url";

const rulesType = "i-have-adhd-rules";
const disabledType = "i-have-adhd-disabled";
const { default: iHaveAdhdExtension } = await import(
  pathToFileURL(process.env.PATCHED_ADHD_LOADER).href,
);
const assert = (condition, message) => {
  if (!condition) throw new Error(message);
};
const custom = customType => ({ role: "custom", customType });
const staleBranch = [{ type: "custom_message", customType: rulesType }];

const createFixture = ({ contextEntries, initialMessages = [] } = {}) => {
  let messages = initialMessages;
  const handlers = new Map();
  const sent = [];
  const context = {
    sessionManager: {
      getBranch: () => staleBranch,
      buildContextEntries: contextEntries,
      buildSessionContext: () => {
        if (contextEntries) throw new Error("native context path should take precedence");
        return { messages };
      },
    },
    ui: {
      setStatus: () => {},
      theme: { fg: (_color, value) => value },
    },
  };
  const pi = {
    appendEntry: () => {},
    getFlag: name => name === "adhd",
    on: (event, handler) => handlers.set(event, handler),
    registerFlag: () => {},
    sendMessage: message => {
      sent.push(message);
      messages = [...messages, custom(message.customType)];
    },
  };

  iHaveAdhdExtension(pi);
  return {
    compact: () => handlers.get("session_compact")({}, context),
    sent,
    setMessages: next => {
      messages = next;
    },
    start: () => handlers.get("session_start")({}, context),
  };
};

const fallback = createFixture();
await fallback.start();
assert(fallback.sent.length === 1, "initial session start did not inject rules");
await fallback.compact();
assert(fallback.sent.length === 1, "retained rules marker injected a duplicate");
fallback.setMessages([]);
await fallback.compact();
assert(fallback.sent.length === 2, "compacted-away rules marker did not reinject exactly once");
await fallback.compact();
assert(fallback.sent.length === 2, "re-injected rules marker did not stop a second duplicate");
fallback.setMessages([{ role: "user", customType: rulesType }]);
await fallback.compact();
assert(fallback.sent.length === 3, "non-custom model message suppressed reinjection");
fallback.setMessages([custom(rulesType), custom(disabledType)]);
await fallback.compact();
assert(fallback.sent.length === 4, "latest disabled marker did not clear rules state");
await fallback.compact();
assert(fallback.sent.length === 4, "rules re-injected after disabled marker did not prevent a duplicate");

const nativeRules = createFixture({
  contextEntries: () => [{ type: "custom_message", customType: rulesType }],
});
await nativeRules.start();
assert(nativeRules.sent.length === 0, "native context entries did not take precedence");
const nativeDisabled = createFixture({
  contextEntries: () => [
    { type: "custom_message", customType: rulesType },
    { type: "custom_message", customType: disabledType },
  ],
});
await nativeDisabled.start();
assert(nativeDisabled.sent.length === 1, "native disabled marker did not clear rules state");
EOF
PATCHED_ADHD_LOADER="$loader" bun "$scratch/test-adhd-compaction.mjs"
cat "$fixture_prefix" "$fixture_upstream" "$fixture_suffix" >"$loader"
sed -i '/^  let active = false;$/a\  const drift = true;' "$loader"
cp "$loader" "$scratch/loader.drifted"
if env HOME="$home" bash "$patch_script" 2>"$scratch/patch-drift.err"; then
  printf 'body-drifted extension loader unexpectedly patched\n' >&2
  exit 1
fi
cmp -s "$scratch/loader.drifted" "$loader" || { echo 'body-drifted loader was rewritten' >&2; exit 1; }
grep -F 'drifted' "$scratch/patch-drift.err" >/dev/null
rm "$loader"
if env HOME="$home" bash "$patch_script" 2>"$scratch/patch-missing.err"; then
  printf 'missing extension loader unexpectedly patched\n' >&2
  exit 1
fi
grep -F 'missing from the extracted tree' "$scratch/patch-missing.err" >/dev/null
printf 'drifted upstream\n' >"$loader"
if env HOME="$home" bash "$patch_script" 2>"$scratch/patch-drift.err"; then
  printf 'drifted extension loader unexpectedly patched\n' >&2
  exit 1
fi
grep -F 'drifted' "$scratch/patch-drift.err" >/dev/null

# Same-version package/config changes must replace the full installed payload.
printf '\n// same-version payload change\n' >>"$source/plugins/mxm4-haptic/dist/index.js"
run_plugins "$scratch/update.calls"
cmp "$source/plugins/mxm4-haptic/package.json" "$home/.omp/plugins/cache/plugins/h82-dotfiles___mxm4-haptic___0.0.0/package.json"
cmp "$source/plugins/mxm4-haptic/dist/index.js" "$home/.omp/plugins/cache/plugins/h82-dotfiles___mxm4-haptic___0.0.0/dist/index.js"
bun "$(dirname "$0")/test-omp-haptic-plugin.ts" "$home/.omp/plugins/cache/plugins/h82-dotfiles___mxm4-haptic___0.0.0"


# --- declared omp settings assertion ---------------------------------------
# CI can prove the provisioner's CALL SHAPE and its catalog branches. It cannot
# prove omp's file-merge semantics: this stub writes no config.yml and the job
# installs no omp, so a byte-level preservation assertion would pass vacuously.
# R10's sibling-preservation guarantee is the documented manual probe against a
# relocated PI_CODING_AGENT_DIR, not this test.
settings_home="$scratch/settings-home"
settings_bin="$scratch/settings-bin"
mkdir -p "$settings_home" "$settings_bin"
cat >"$settings_bin/omp" <<'EOF'
#!/usr/bin/env bash
if [ "${1-}" = "models" ]; then
  if [ -n "${CANNED_CATALOG-}" ]; then
    cat "$CANNED_CATALOG"
    exit 0
  fi
  printf 'no catalog\n' >&2
  exit 1
fi
printf '%s\n' "$*" >>"$OMP_CALLS"
EOF
chmod 0755 "$settings_bin/omp"

# The declared map is embedded in the rendered script, so the fixtures below
# track the data instead of hardcoding a model list that would rot.
declared_json="$scratch/declared.json"
awk '/^cat >"\$declared"/{flag=1;next}/^JSON$/{flag=0}flag' "$settings_script" >"$declared_json"
jq -e 'type == "object" and (keys | length) > 0' "$declared_json" >/dev/null

# The harvest is shared by the catalog fixture and the shape check. A chain KEY
# is a selector too when it is model-oriented, so it must be harvested alongside
# the hop values. It is filtered HERE rather than downstream because the shape
# check below consumes this harvest raw: a role-keyed chain key is not a selector
# and would fail that check as a malformed one.
harvest_selectors='
  def strip_thinking: sub(":(off|minimal|low|medium|high|xhigh|max)$"; "");
  [ (.modelRoles // {} | to_entries[].value),
    (."task.agentModelOverrides" // {} | to_entries[].value),
    (."retry.fallbackChains" // {} | to_entries[].value[]),
    (."retry.fallbackChains" // {} | to_entries[] | .key | select(contains("/"))) ]
  | map(select(type == "string")) | map(select(startswith("@") | not))'

jq -r "$harvest_selectors
  | map(strip_thinking) | map(select(endswith(\"/*\") | not))
  | map(select(contains(\"/\"))) | unique
  | {models: map({provider: (split(\"/\")[0]), selector: .})}
" "$declared_json" >"$scratch/catalog-full.json"
jq -e '(.models | length) > 0' "$scratch/catalog-full.json" >/dev/null

# Chain reachability, asserted against the SHIPPED data rather than a fixture.
# omp looks a chain up by the failing model's id, so a model-keyed chain whose
# model no role, agent override, or hop ever produces is dead data — the symptom
# is a tier that silently loses its recovery path after a retune.
#
# This cannot be a render-time check in the validator, and that is not a style
# choice: `--override-data` DEEP-MERGES, so every fixture that retunes one role
# inherits the real chains and manufactures an orphan the validator would then
# reject. The invariant is global over one complete policy, so it is checked once
# here, over exactly the data that ships. A key naming a HOP is legitimate: that
# hop can fail and own a chain in turn.
unnamed=$(jq -r '
  def strip_thinking: sub(":(off|minimal|low|medium|high|xhigh|max)$"; "");
  ([ (.modelRoles // {} | to_entries[].value),
     (."task.agentModelOverrides" // {} | to_entries[].value),
     (."retry.fallbackChains" // {} | to_entries[].value[])
   ] | map(select(type == "string") | select(startswith("@") | not) | strip_thinking) | unique) as $named
  | (."retry.fallbackChains" // {} | keys | map(select(contains("/"))))
  | map(select(strip_thinking as $k | ($named | index($k)) == null))
  | .[]
' "$declared_json")
if [[ -n $unnamed ]]; then
  while IFS= read -r key; do
    [[ -n $key ]] || continue
    printf 'chain-reachability: retry.fallbackChains is keyed on %s, which no modelRoles selector, task.agentModelOverrides value, or chain hop names; omp looks a chain up by the failing model id, so it can never be consulted\n' "$key" >&2
  done <<<"$unnamed"
  exit 1
fi

declared_count=$(jq -r 'keys | length' "$declared_json")

run_settings() {
  local label=$1 catalog=$2
  : >"$scratch/$label.calls"
  # An empty CANNED_CATALOG and an unset one take the same stub path, so the
  # assignment needs no fork.
  OMP_CALLS="$scratch/$label.calls" CANNED_CATALOG="$catalog" \
    env HOME="$settings_home" PATH="$settings_bin:$PATH" \
    bash "$settings_script" >"$scratch/$label.out" 2>"$scratch/$label.err"
}

# One assertion per declared path, at the exact value the contract requires, and
# never at a parent namespace. Comparing the whole recorded call is what makes
# this load-bearing: a prefix match passes even when the provisioner delivers
# every record as a literal string, which is the entire model policy.
run_settings full "$scratch/catalog-full.json"
[[ $(wc -l <"$scratch/full.calls") -eq $declared_count ]]
while IFS=$'\t' read -r path want; do
  grep -qxF "config set $path $want" "$scratch/full.calls" || {
    printf 'settings assertion did not deliver declared path %s as %s\n' "$path" "$want" >&2
    printf '  recorded: %s\n' "$(grep -F "config set $path " "$scratch/full.calls" || echo '(absent)')" >&2
    exit 1
  }
done < <(jq -r '
  to_entries[]
  | [.key, (if (.value | type) == "string" then .value else (.value | tojson) end)]
  | @tsv
' "$declared_json")
# Derived from the declared keys, so a newly declared dotted path is guarded too.
while IFS= read -r parent; do
  if grep -qF "config set $parent " "$scratch/full.calls"; then
    printf 'settings assertion wrote parent namespace %s\n' "$parent" >&2
    exit 1
  fi
done < <(jq -r 'keys[] | select(contains(".")) | split(".")[0]' "$declared_json" | sort -u)
grep -F "asserted $declared_count declared omp settings paths" "$scratch/full.out" >/dev/null

# A selector the catalog covers by provider but does not serve aborts the apply
# before anything is written.
absent_selector=$(jq -r 'first(.models[] | select(.provider == "anthropic") | .selector) // ""' "$scratch/catalog-full.json")
[[ -n $absent_selector ]] || {
  printf 'fixture found no anthropic selector to withhold; the absent-selector case is not being exercised\n' >&2
  exit 1
}
jq --arg s "$absent_selector" '.models |= map(select(.selector != $s))' \
  "$scratch/catalog-full.json" >"$scratch/catalog-absent.json"
if run_settings absent "$scratch/catalog-absent.json"; then
  printf 'settings assertion accepted a selector the catalog does not serve\n' >&2
  exit 1
fi
grep -F "names $absent_selector" "$scratch/absent.err" >/dev/null
grep -F 'does not serve' "$scratch/absent.err" >/dev/null
[[ ! -s "$scratch/absent.calls" ]]

# A provider the catalog cannot speak for is not evidence of an absent selector.
jq '.models |= map(select(.provider != "anthropic"))' \
  "$scratch/catalog-full.json" >"$scratch/catalog-noprovider.json"
run_settings noprovider "$scratch/catalog-noprovider.json"
grep -F 'catalog has no anthropic models' "$scratch/noprovider.err" >/dev/null
[[ $(wc -l <"$scratch/noprovider.calls") -eq $declared_count ]]

# An unparseable catalog and a failing probe both fail open.
printf 'not json\n' >"$scratch/catalog-bad.json"
run_settings badcatalog "$scratch/catalog-bad.json"
grep -F 'model catalog unavailable' "$scratch/badcatalog.err" >/dev/null
[[ $(wc -l <"$scratch/badcatalog.calls") -eq $declared_count ]]

run_settings failcatalog ''
grep -F 'model catalog unavailable' "$scratch/failcatalog.err" >/dev/null
[[ $(wc -l <"$scratch/failcatalog.calls") -eq $declared_count ]]

# A missing omp binary is a soft skip, not a failed apply.
env HOME="$settings_home" PATH="/usr/bin:/bin" bash "$settings_script" \
  >"$scratch/noomp.out" 2>"$scratch/noomp.err"
grep -F 'omp is unavailable' "$scratch/noomp.err" >/dev/null

# A live-catalog freshness probe is not possible here: the job installs no omp
# and holds no provider credentials. This shape check is the feasible
# substitute — it catches a typo in a provider, a model id, or a thinking level
# at PR time, while the provisioner's own catalog gate catches a retired id on
# the host that actually has the credentials.
mapfile -t declared_selectors < <(jq -r "$harvest_selectors | unique | .[]" "$declared_json")
[[ ${#declared_selectors[@]} -gt 0 ]] || {
  printf 'no declared model selectors extracted; the selector shape check would pass vacuously\n' >&2
  exit 1
}
for selector in "${declared_selectors[@]}"; do
  if [[ ! $selector =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?/[A-Za-z0-9._*-]+(:(off|minimal|low|medium|high|xhigh|max))?$ ]]; then
    printf 'malformed declared model selector: %s\n' "$selector" >&2
    exit 1
  fi
done

# Render-time guards are structurally invisible to every test above, which receives
# already-rendered scripts. These cases fail the RENDER, the only layer that can
# still catch them: the apply-time catalog gate skips role aliases by design, and
# omp stores a nonsense selector silently. Requires chezmoi, which the job that
# rendered the scripts under test already installed.
# Reuse the repository root resolved before the release-lock assertions.
render_config="$scratch/render.toml"
: >"$render_config"
# A guard that fires AFTER a credential field is resolved (the duplicate check is
# one) still performs a live op read, so isolate the render from host secret
# state: a scratch HOME and a stub op answering with a newline-free value keep
# that read off the host without changing what the guard observes.
neg_home="$scratch/neg-home"
neg_bin="$scratch/neg-bin"
mkdir -p "$neg_home" "$neg_bin"
printf '#!/usr/bin/env bash\ncase "${1-}" in whoami) printf dummy@example.invalid;; *) printf dummy-secret;; esac\n' >"$neg_bin/op"
chmod 0700 "$neg_bin/op"
assert_render_fails() {
  local label=$1 template=$2 data=$3 want=$4
  if env HOME="$neg_home" PATH="$neg_bin:$PATH" \
    chezmoi --config "$render_config" --source "$repo_root" --override-data "$data" \
    execute-template <"$repo_root/$template" >"$scratch/neg.out" 2>"$scratch/neg.err"; then
    printf 'render-negative %s: expected a failed render, got exit 0\n' "$label" >&2
    exit 1
  fi
  grep -qF -e "$want" -- "$scratch/neg.err" || {
    printf 'render-negative %s: render failed without the expected diagnostic %s\n' "$label" "$want" >&2
    sed 's/^/  /' "$scratch/neg.err" >&2
    exit 1
  }
}
# `--override-data` DEEP-MERGES into the repo's real agents.yaml, so a fixture can
# only add a bad value — it can never express an ABSENT key, because the real
# declaration survives the merge. This renders inline template text that builds
# its own settings dict, which is the only way to test absence.
assert_partial_fails() {
  local label=$1 body=$2 want=$3
  printf '%s\n' "$body" >"$scratch/partial.tmpl"
  if env HOME="$neg_home" PATH="$neg_bin:$PATH" \
    chezmoi --config "$render_config" --source "$repo_root" \
    execute-template <"$scratch/partial.tmpl" >"$scratch/neg.out" 2>"$scratch/neg.err"; then
    printf 'render-partial %s: expected a failed render, got exit 0\n' "$label" >&2
    exit 1
  fi
  grep -qF -e "$want" -- "$scratch/neg.err" || {
    printf 'render-partial %s: render failed without the expected diagnostic %s\n' "$label" "$want" >&2
    sed 's/^/  /' "$scratch/neg.err" >&2
    exit 1
  }
}
assert_render_ok() {
  local label=$1 template=$2 data=$3
  env HOME="$neg_home" PATH="$neg_bin:$PATH" \
    chezmoi --config "$render_config" --source "$repo_root" --override-data "$data" \
    execute-template <"$repo_root/$template" >"$scratch/pos.out" 2>"$scratch/pos.err" || {
    printf 'render-positive %s: expected a successful render, got a failure\n' "$label" >&2
    sed 's/^/  /' "$scratch/pos.err" >&2
    exit 1
  }
}

auth_sh='.chezmoiscripts/70-agents/run_after_config-omp-auth.sh.tmpl'
settings_sh='.chezmoiscripts/70-agents/run_after_config-omp-settings.sh.tmpl'
linux='"chezmoi":{"os":"linux"}'
roles='"modelRoles":{"default":"anthropic/claude-opus-5:xhigh"}'
models_yml='dot_omp/private_agent/readonly_models.yml.tmpl'
closed_set='EXA_API_KEY, OPENROUTER_API_KEY, OPENCODE_API_KEY'

# The credential set is closed on both platforms so a data edit cannot inject a
# variable into the environment omp loads for every session, nor silently drop
# one.
assert_render_fails auth-outside-closed-set-linux "$auth_sh" \
  "{$linux,\"agents\":{\"omp\":{\"auth\":{\"env\":[{\"variable\":\"NODE_OPTIONS\",\"key\":\"x\"}]}}}}" \
  "declares unsupported variable \"NODE_OPTIONS\"; the closed set is $closed_set"
assert_render_fails auth-emptied-set-linux "$auth_sh" \
  "{$linux,\"agents\":{\"omp\":{\"auth\":{\"env\":[]}}}}" \
  'must declare EXA_API_KEY'
assert_render_fails auth-duplicate-linux "$auth_sh" \
  "{$linux,\"agents\":{\"omp\":{\"auth\":{\"env\":[{\"variable\":\"EXA_API_KEY\",\"key\":\"a\"},{\"variable\":\"EXA_API_KEY\",\"key\":\"b\"}]}}}}" \
  'duplicates variable "EXA_API_KEY"'
assert_render_fails auth-empty-key-linux "$auth_sh" \
  "{$linux,\"agents\":{\"omp\":{\"auth\":{\"env\":[{\"variable\":\"EXA_API_KEY\",\"key\":\"\"}]}}}}" \
  'resolved to an empty value'
assert_render_fails auth-non-string-key-linux "$auth_sh" \
  "{$linux,\"agents\":{\"omp\":{\"auth\":{\"env\":[{\"variable\":\"EXA_API_KEY\",\"key\":[\"not-a-string\"]}]}}}}" \
  'field `key` must resolve to a string'

# Role indirection is the one value shape no later layer validates.
assert_render_fails settings-dangling-alias "$settings_sh" \
  "{$linux,\"agents\":{\"omp\":{\"settings\":{$roles,\"task.agentModelOverrides\":{\"commit\":\"@no-such-role\"}}}}}" \
  'names role alias @no-such-role'
# A chain key means a model when it contains a slash and a role when it does not.
# Both illegal shapes are invisible to the catalog gate: it strips the thinking
# suffix before comparing, and it treats a wildcard as routing syntax.
assert_render_fails settings-orphan-chain "$settings_sh" \
  "{$linux,\"agents\":{\"omp\":{\"settings\":{$roles,\"retry.fallbackChains\":{\"ghost\":[\"anthropic/claude-opus-5:xhigh\"]}}}}}" \
  'is neither a provider/model-id selector nor a declared modelRoles role'
assert_render_fails settings-wildcard-chain-key "$settings_sh" \
  "{$linux,\"agents\":{\"omp\":{\"settings\":{$roles,\"retry.fallbackChains\":{\"anthropic/*\":[\"anthropic/claude-sonnet-5\"]}}}}}" \
  'is a provider wildcard'
assert_render_fails settings-suffixed-chain-key "$settings_sh" \
  "{$linux,\"agents\":{\"omp\":{\"settings\":{$roles,\"retry.fallbackChains\":{\"anthropic/claude-opus-5:max\":[\"anthropic/claude-sonnet-5\"]}}}}}" \
  'carries a thinking suffix'
# The kimi-k3 hop is load-bearing, not decoration: --override-data deep-merges,
# so this fixture REPLACES the shipped anthropic/claude-opus-5 chain while still
# inheriting the real agents.omp.models override for opencode-go/kimi-k3. That
# hop is the shipped data's only declaration of it, so dropping it here orphans
# the override and this positive fixture fails for a reason it does not test.
# The orphan rule itself is covered by models-declared/undeclared-override below.
assert_render_ok settings-model-keyed-chain "$settings_sh" \
  "{$linux,\"agents\":{\"omp\":{\"settings\":{$roles,\"retry.fallbackChains\":{\"anthropic/claude-opus-5\":[\"anthropic/claude-sonnet-5\",\"opencode-go/kimi-k3:max\"]}}}}}"
# agents.omp.models is parasitic on the settings: an override nothing declares is
# dead data omp ignores, only modelOverrides may appear under a provider, and the
# credential-free contract applies to it too. Its diagnostics name that surface.
models_settings="$roles,\"retry.fallbackChains\":{\"anthropic/claude-opus-5\":[\"opencode-go/kimi-k3:high\"]}"
assert_render_ok models-declared-override "$models_yml" \
  "{$linux,\"agents\":{\"omp\":{\"settings\":{$models_settings},\"models\":{\"providers\":{\"opencode-go\":{\"modelOverrides\":{\"kimi-k3\":{\"contextWindow\":262144}}}}}}}}"
assert_render_fails models-undeclared-override "$models_yml" \
  "{$linux,\"agents\":{\"omp\":{\"settings\":{$models_settings},\"models\":{\"providers\":{\"opencode-go\":{\"modelOverrides\":{\"kimi-k9\":{\"contextWindow\":262144}}}}}}}}" \
  'which no declared agents.omp.settings selector names'
assert_render_fails models-non-override-key "$models_yml" \
  "{$linux,\"agents\":{\"omp\":{\"settings\":{$models_settings},\"models\":{\"providers\":{\"opencode-go\":{\"baseUrl\":\"https://x.invalid\"}}}}}}" \
  'but only modelOverrides is permitted here'
assert_render_fails models-credential-reference "$models_yml" \
  "{$linux,\"agents\":{\"omp\":{\"settings\":{$models_settings},\"models\":{\"providers\":{\"opencode-go\":{\"modelOverrides\":{\"kimi-k3\":{\"headers\":{\"X\":\"op://Private/x/y\"}}}}}}}}}" \
  'provider opencode-go carries an op:// reference'
assert_render_fails models-credential-provider-key "$models_yml" \
  "{$linux,\"agents\":{\"omp\":{\"settings\":{$models_settings},\"models\":{\"providers\":{\"op://Private/x/y\":{}}}}}}" \
  'agents.omp.models carries an op:// reference'
# A selector never reaches the shell as a word or a script fragment, but the
# top-level charset check cannot see one: it is gated on a string-typed top-level
# value, and every selector lives inside a record. These two prove the nested
# check that closes that gap — one quote in a selector must not survive a render.
assert_render_fails settings-unsafe-role-selector "$settings_sh" \
  "{$linux,\"agents\":{\"omp\":{\"settings\":{\"modelRoles\":{\"default\":\"anthropic/claude-opus-5:xhigh\",\"advisor\":\"evil'; touch /tmp/x #/y\"},\"advisor.enabled\":true}}}}" \
  'has a value outside the safe charset'
assert_render_fails settings-unsafe-chain-hop "$settings_sh" \
  "{$linux,\"agents\":{\"omp\":{\"settings\":{$roles,\"retry.fallbackChains\":{\"default\":[\"a';id;'/b\"]}}}}}" \
  'has a value outside the safe charset'
# advisor.enabled and modelRoles.advisor are paired by convention only; without
# an advisor role the seat goes inert with nothing naming a cause. This needs the
# inline-text helper: an override cannot delete the real advisor role.
assert_partial_fails settings-advisor-without-role \
  '{{- includeTemplate "omp-settings-validate.tmpl" (dict "ctx" . "settings" (dict "modelRoles" (dict "default" "anthropic/claude-opus-5:xhigh") "advisor.enabled" true) "models" dict) -}}' \
  'modelRoles declares no advisor role'
# A control character anywhere in the value breaks the tab-separated transport.
assert_render_fails settings-nested-control-char "$settings_sh" \
  "{$linux,\"agents\":{\"omp\":{\"settings\":{\"modelRoles\":{\"default\":\"anthropic/claude-opus-5\txhigh\"}}}}}" \
  'control character or backslash somewhere in its value'
assert_render_fails settings-parent-namespace "$settings_sh" \
  "{$linux,\"agents\":{\"omp\":{\"settings\":{$roles,\"exa\":true,\"exa.enableSearch\":true}}}}" \
  'is a parent namespace of'

printf 'omp auth, plugin, and settings reconcile tests passed\n'
