#!/usr/bin/env bash
# scripts/linux/config-solaar.sh
#
# Apply per-device Solaar settings to ~/.config/solaar/config.yaml that
# CANNOT be expressed via the symlinked rules.yaml. Currently:
#
#   1. divert-keys: route specific reprogrammable buttons through Solaar's
#      rule engine (HID++ notifications) instead of the device firmware
#      default (which sends a stock mouse button).
#
# Haptic intensity (`haptic-level`) is intentionally NOT enforced here —
# leave that to the user's Solaar GUI preference. The mxm4-haptic helper
# writes raw HID++ haptic-play with no ack wait, so intermittent
# perceptibility at low intensity (a Bolt-wireless ack-variance artefact
# of Solaar's own `Set` write path) is no longer a concern.
#
# Why not symlink config.yaml itself: the file embeds per-physical-device
# state (_serial, _unitId, _battery, _absent feature list) alongside the
# settings we want to manage. Tracking it verbatim would couple the repo
# to one mouse unit, break on hardware replacement, and produce noisy
# diffs every time Solaar updates battery readings.
#
# Why not `solaar config <setting> <value>`: Solaar 1.1.19 hits
#   TypeError: Unable to marshal str as an array
# inside Gio.Application.run when persisting the change. The runtime
# device state flips (so the rule fires once or the pulse plays once);
# the on-disk config does not. GUI path persists correctly but isn't
# automatable.
#
# This script edits the file directly with PyYAML and only restarts
# Solaar if it actually changed something. PyYAML is a Solaar rpm
# requirement, so importing yaml via /usr/bin/python3 (NOT bare
# `python3`, which mise may shadow) is guaranteed wherever Solaar is.
#
# Soft-skips when:
#   - solaar not installed (nothing to configure)
#   - ~/.config/solaar/config.yaml absent (no devices paired yet)
#   - target device not present in config.yaml (paired on another host only)
#   - PyYAML unreachable via /usr/bin/python3 (defensive; Solaar rpm pulls it)
#
# Idempotent: re-running on an already-correct config writes nothing,
# touches no backup, does not restart Solaar.

set -euo pipefail

CONFIG="${HOME}/.config/solaar/config.yaml"
PYTHON=/usr/bin/python3
SOLAAR_SERVICE=app-solaar@autostart.service

# Per-device targets, one per line: "<model_id>:<setting_path>:<value>:<label>"
#   model_id     : 12-hex from `solaar show` -> Model ID line.
#   setting_path : either a scalar setting name (e.g. `haptic-level`) or
#                  a nested-dict path (e.g. `divert-keys.416`). The script
#                  splits on the first dot: no dot means scalar, dot means
#                  the second part is an int key into the named dict.
#   value        : int. Interpreted per setting (see below).
#   label        : free-form, only for log output.
#
# Setting reference for MX Master 4 (model B04200000000):
#   divert-keys.<control_id> : 0=Regular, 1=Diverted, 2=Sliding DPI,
#                              3=Mouse Gestures (per
#                              logitech_receiver.settings_templates.DivertKeys).
#                              Control IDs from `solaar show` reprogrammable
#                              keys section: 416 = Haptic thumb button.
#
# For nested-dict settings the path is `<setting>.<int_key>` (e.g.
# `divert-keys.416`). For scalar settings the path is just the setting
# name (e.g. `haptic-level` — supported by the parser even though no
# scalar target is currently enforced; add one here if a future setting
# needs lockstep cross-machine state).
TARGETS=(
  "B04200000000:divert-keys.416:1:MX Master 4 / Haptic -> Diverted"
)

# 0. Skip if Solaar isn't installed: nothing to configure.
if ! command -v solaar >/dev/null 2>&1; then
  echo "config-solaar: solaar not installed; skipping" >&2
  exit 0
fi

# 1. Skip if config.yaml hasn't been generated yet (no devices paired).
if [[ ! -f "$CONFIG" ]]; then
  echo "config-solaar: $CONFIG not present (no devices paired yet); skipping" >&2
  exit 0
fi

# 2. Skip if PyYAML isn't reachable via system Python. Should be
#    impossible when solaar rpm is installed; defensive guard for
#    non-rpm Solaar installs (pip --user, etc.).
if ! "$PYTHON" -c "import yaml" 2>/dev/null; then
  echo "config-solaar: PyYAML not available via $PYTHON; skipping" >&2
  exit 0
fi

# 3. Apply targets via inline Python: load, mutate, atomic write, log.
RESULT=$("$PYTHON" - "$CONFIG" "${TARGETS[@]}" <<'PYEOF'
import os
import shutil
import sys

import yaml

config_path = sys.argv[1]
targets = []
for spec in sys.argv[2:]:
    parts = spec.split(":", 3)
    if len(parts) < 4:
        sys.stderr.write(
            f"config-solaar: malformed target {spec!r}; "
            f"need model:setting_path:value:label\n"
        )
        continue
    model_id, setting_path, value_str, label = parts
    try:
        value = int(value_str)
    except ValueError:
        sys.stderr.write(
            f"config-solaar: non-int value {value_str!r} in {spec!r}; skipping\n"
        )
        continue
    if "." in setting_path:
        setting_name, key_str = setting_path.split(".", 1)
        try:
            key = int(key_str)
        except ValueError:
            sys.stderr.write(
                f"config-solaar: non-int dict key {key_str!r} in {spec!r}; skipping\n"
            )
            continue
    else:
        setting_name = setting_path
        key = None
    targets.append((model_id, setting_name, key, value, label))

with open(config_path) as f:
    doc = yaml.safe_load(f)

# Solaar's config.yaml is a single document whose top level is a list:
# the first element is the Solaar version string, the rest are per-device
# dicts. Bail out cleanly if Solaar changes the schema rather than risk
# corrupting it.
if not isinstance(doc, list):
    print("UNCHANGED:UNEXPECTED_SCHEMA: top-level not a list")
    sys.exit(0)

changed_labels = []
skipped_labels = []
for model_id, setting_name, key, value, label in targets:
    device = next(
        (entry for entry in doc
         if isinstance(entry, dict) and entry.get("_modelId") == model_id),
        None,
    )
    if device is None:
        skipped_labels.append(f"{label} (model {model_id} not in config)")
        continue
    if key is None:
        # Scalar setting (e.g. haptic-level).
        if device.get(setting_name) == value:
            continue
        device[setting_name] = value
    else:
        # Nested-dict setting (e.g. divert-keys.416).
        existing = device.get(setting_name)
        if existing is None:
            existing = {}
        if not isinstance(existing, dict):
            skipped_labels.append(
                f"{label} ({setting_name} not a dict in config)"
            )
            continue
        if existing.get(key) == value:
            continue
        existing[key] = value
        device[setting_name] = existing
    changed_labels.append(label)

if not changed_labels:
    if skipped_labels:
        print("UNCHANGED:SKIPPED:" + "; ".join(skipped_labels))
    else:
        print("UNCHANGED")
    sys.exit(0)

# Atomic write: backup the previous config, write to temp, rename in place.
shutil.copy2(config_path, config_path + ".bak")
tmp = config_path + ".new"
with open(tmp, "w") as f:
    yaml.safe_dump(doc, f, default_flow_style=None, sort_keys=False,
                   allow_unicode=True)
os.replace(tmp, config_path)

msg = "CHANGED:" + "; ".join(changed_labels)
if skipped_labels:
    msg += " | SKIPPED:" + "; ".join(skipped_labels)
print(msg)
PYEOF
)

echo "config-solaar: $RESULT"

# 4. Restart Solaar only when we actually wrote something AND a user
#    systemd manager owns the unit. On a fresh install where Solaar is
#    not yet running, new state loads at next user-session login.
if [[ "$RESULT" == CHANGED:* ]]; then
  if systemctl --user is-active --quiet "$SOLAAR_SERVICE" 2>/dev/null; then
    systemctl --user restart "$SOLAAR_SERVICE"
    echo "config-solaar: restarted $SOLAAR_SERVICE"
  else
    echo "config-solaar: $SOLAAR_SERVICE not running; new state will load on next Solaar start" >&2
  fi
fi

# 5. Populate ~/.cache/mxm4-haptic.json with the MX Master 4 device index
#    on the Bolt receiver and the HAPTIC feature index. Required by the
#    `mxm4-haptic` binary (Rust crate at crates/mxm4-haptic/, built into
#    ~/.local/bin/ by install.linux.yaml) which writes raw HID++ Long
#    reports directly to the Bolt receiver's hidraw to bypass Solaar's
#    ack-wait variance.
#
#    Source of truth: `solaar show`, parsed below by `solaar show` model
#    id and HAPTIC {19B0} feature lines. This is the only canonical
#    source — at runtime, Solaar holds the HID++ session and any read
#    contention loses the response to Solaar's reader thread. Discovery
#    must happen at install time.
#
#    Cache stays in ~/.cache (persistent across reboots; hidraw numbering
#    in /dev is NOT persistent so the helper re-resolves the hidraw node
#    at runtime by walking /sys/class/hidraw). Re-run this script after
#    re-pairing the mouse or pairing other devices first.
"$PYTHON" - "$HOME/.cache/mxm4-haptic.json" <<'PYEOF'
import json
import os
import pathlib
import re
import subprocess
import sys

cache_path = pathlib.Path(sys.argv[1])

# Target: MX Master 4 model id. Edit this constant if managing a
# different Logitech device with HAPTIC.
TARGET_MODEL_ID = "B04200000000"

result = subprocess.run(
    ["solaar", "show"],
    capture_output=True,
    text=True,
    timeout=30,
)
if result.returncode != 0:
    print(f"config-solaar (cache): solaar show exit={result.returncode}; skipping",
          file=sys.stderr)
    sys.exit(0)

# Parse `solaar show` output. Per-device block looks like:
#
#   1: MX Master 4
#      Device path  : None
#      ...
#      Model ID:      B04200000000
#      ...
#      Supports N HID++ 2.0 features:
#         0: ROOT                   {0000} V0
#         ...
#        11: HAPTIC                 {19B0} V0
#         ...
#
# We need (device_idx, haptic_feature_idx) for TARGET_MODEL_ID.

device_re = re.compile(r"^\s+(\d+):\s+\S")
model_re = re.compile(r"^\s+Model ID:\s+([0-9A-Fa-f]+)\s*$")
feature_re = re.compile(r"^\s+(\d+):\s+HAPTIC\b")

current_dev_idx = None
current_model = None
matched_dev_idx = None
matched_haptic_idx = None
in_target_features = False

for line in result.stdout.splitlines():
    m = device_re.match(line)
    if m and not line.lstrip().startswith(("0:", "1:", "2:")) is False:
        # device_re is loose; tighten by requiring the line to be the
        # outermost "N: <name>" pattern (4 leading spaces in solaar's
        # current output). Features have 8+ leading spaces.
        leading = len(line) - len(line.lstrip(" "))
        if leading <= 4:
            current_dev_idx = int(m.group(1))
            current_model = None
            in_target_features = False
            continue
    m = model_re.match(line)
    if m:
        current_model = m.group(1).upper()
        if current_model == TARGET_MODEL_ID:
            matched_dev_idx = current_dev_idx
            in_target_features = True
        else:
            in_target_features = False
        continue
    if in_target_features:
        m = feature_re.match(line)
        if m:
            matched_haptic_idx = int(m.group(1))
            break

if matched_dev_idx is None:
    print(
        f"config-solaar (cache): MX Master 4 (model {TARGET_MODEL_ID}) not "
        f"found in solaar show; skipping",
        file=sys.stderr,
    )
    sys.exit(0)
if matched_haptic_idx is None:
    print(
        f"config-solaar (cache): HAPTIC feature not found on MX Master 4; "
        f"skipping (device may be offline)",
        file=sys.stderr,
    )
    sys.exit(0)

old_state = {}
if cache_path.exists():
    try:
        loaded = json.loads(cache_path.read_text())
        if isinstance(loaded, dict):
            old_state = loaded
    except (json.JSONDecodeError, OSError):
        old_state = {}

# Preserve the binary-managed `hidraw` field: the mxm4-haptic binary
# resolves and caches the /dev/hidrawN node on first run. Only overwrite
# the indices we own here. If dev_idx changed (re-pairing), the stale
# hidraw is harmless — the binary re-resolves on the next open failure.
new_state = dict(old_state)
new_state["dev_idx"] = matched_dev_idx
new_state["haptic_idx"] = matched_haptic_idx

if old_state == new_state:
    print(f"config-solaar (cache): UNCHANGED at {cache_path} "
          f"(dev_idx={matched_dev_idx} haptic_idx={matched_haptic_idx})")
    sys.exit(0)

cache_path.parent.mkdir(parents=True, exist_ok=True)
tmp = cache_path.with_suffix(cache_path.suffix + ".new")
tmp.write_text(json.dumps(new_state))
os.replace(tmp, cache_path)
print(f"config-solaar (cache): wrote {cache_path} "
      f"(dev_idx={matched_dev_idx} haptic_idx={matched_haptic_idx})")
PYEOF

exit 0
