# shellcheck shell=bash
# .ci/lib/gem80-firmware-data.sh — reads pinned gem80 firmware facts out of
# .chezmoidata/firmware.yaml, sourced (never executed directly).
#
# WHY A SHARED READER. Both gem80 gates need the same two things from the same
# file, and each having its own decoder means the daily gate and the weekly gate
# can disagree about what the pin is. One reader keeps them on one answer.
#
# WHY NOT jq. The rest of .ci reads JSON with jq, but this file is YAML. CI
# installs python3-yaml for the workflow parser in test-ci-wiring.sh, so PyYAML
# is the repository's YAML decoder; the sed fallback exists so the gates stay
# runnable on a host that has python3 without it.

# Prints the value at a dotted key path, or nothing when it is absent.
gem80_firmware_yaml_get() {
  local yaml_file="$1" key_path="$2"

  [ -f "$yaml_file" ] || return 1

  if command -v python3 >/dev/null 2>&1; then
    local value rc
    value=$(python3 -c '
import sys
try:
    import yaml
except ImportError:
    sys.exit(2)
try:
    with open(sys.argv[1], "r", encoding="utf-8") as handle:
        node = yaml.safe_load(handle)
    for part in sys.argv[2].split("."):
        node = node[part]
except Exception:
    sys.exit(1)
if node is not None:
    print(node)
' "$yaml_file" "$key_path" 2>/dev/null) && rc=0 || rc=$?

    # Exit 2 is "no PyYAML" and falls through to sed. Exit 1 is "key absent",
    # which the decoder answered authoritatively, so do not guess with sed.
    if [ "$rc" -eq 0 ]; then
      printf '%s\n' "$value"
      return 0
    elif [ "$rc" -ne 2 ]; then
      return 1
    fi
  fi

  # The fallback matches the leaf key alone. firmware.yaml nests each leaf under
  # exactly one parent chain, so a leaf name is unambiguous within this file.
  local leaf="${key_path##*.}"
  sed -n -E "s/^[[:space:]]*${leaf}:[[:space:]]*[\"']?([^\"'[:space:]]+)[\"']?[[:space:]]*$/\1/p" \
    "$yaml_file" | head -n 1
}
