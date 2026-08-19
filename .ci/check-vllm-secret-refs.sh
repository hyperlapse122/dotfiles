#!/usr/bin/env bash
set -euo pipefail

root=${1:-.}
target_files=()

if [[ -f "$root" ]]; then
  target_files+=("$root")
elif [[ -d "$root" ]]; then
  if [[ -d "$root/.chezmoidata" ]]; then
    shopt -s nullglob
    target_files+=("$root/.chezmoidata"/*.yaml)
    shopt -u nullglob
  else
    shopt -s nullglob
    target_files+=("$root"/*.yaml)
    shopt -u nullglob
  fi
else
  printf '::error::check-vllm-secret-refs: scan path does not exist: %s\n' "$root" >&2
  exit 1
fi

if [[ ${#target_files[@]} -eq 0 ]]; then
  printf '::error::check-vllm-secret-refs: no YAML files found in %s\n' "$root" >&2
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  printf '::error::check-vllm-secret-refs: python3 is required for YAML parsing\n' >&2
  exit 1
fi

python3 - "${target_files[@]}" <<'PY'
import re
import sys
from pathlib import Path

target_paths = [Path(p) for p in sys.argv[1:]]
errors = []

for target in target_paths:
    try:
        content = target.read_text(encoding="utf-8")
    except Exception as e:
        errors.append(f"cannot read {target}: {e}")
        continue

    lines = content.splitlines()
    is_vllm = (target.name == "vllm.yaml")
    in_auth = False
    auth_indent = None
    found_api_key_ref = False

    for idx, line in enumerate(lines, start=1):
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue

        indent = len(line) - len(line.lstrip())

        if in_auth and indent <= auth_indent and ":" in stripped and not stripped.startswith("-"):
            in_auth = False

        m = re.match(r'^(?:"([^"]+)"|\'([^\']+)\'|([A-Za-z0-9_.-]+))\s*:\s*(.*)$', stripped)
        key = None
        val = ""
        if m:
            key = m.group(1) or m.group(2) or m.group(3)
            val = m.group(4).strip()
            if val and not (val.startswith('"') or val.startswith("'")):
                if " #" in val:
                    val = val.split(" #", 1)[0].strip()

        if is_vllm and key == "auth" and (not val or val.startswith("{")):
            in_auth = True
            auth_indent = indent
            continue

        val_unquoted = val
        if (val.startswith('"') and val.endswith('"')) or (val.startswith("'") and val.endswith("'")):
            val_unquoted = val[1:-1].strip()

        if is_vllm and in_auth:
            if key:
                if any(t in key.lower() for t in ["key", "secret", "token"]):
                    if key == "apiKeyRef":
                        found_api_key_ref = True
                    if not val_unquoted.startswith("op://"):
                        label = "apiKeyRef" if key == "apiKeyRef" else f"auth property {key}"
                        errors.append(f"{target}:{idx}: {label} must be an op:// reference, got: {val_unquoted!r}")

        if re.search(r'vllm_api_key\s*=', stripped, re.IGNORECASE):
            errors.append(f"{target}:{idx}: possible literal secret in tracked YAML: {stripped}")

        if key:
            key_lower = key.lower().replace("-", "").replace("_", "")
            if key_lower in ["apikey", "apisecret", "secretkey", "authtoken", "vllmapikey", "apikeyref"]:
                if val_unquoted and not val_unquoted.startswith("op://") and not val_unquoted.startswith("[") and not val_unquoted.startswith("{"):
                    errors.append(f"{target}:{idx}: possible literal secret in tracked YAML: {stripped}")

        if val_unquoted:
            if re.search(r'\b(sk-[A-Za-z0-9_-]{20,}|ghp_[A-Za-z0-9]{20,}|glpat-[A-Za-z0-9_-]{20,})\b', val_unquoted):
                if not val_unquoted.startswith("op://"):
                    errors.append(f"{target}:{idx}: possible literal secret in tracked YAML: {stripped}")

    if is_vllm and not found_api_key_ref:
        errors.append(f"{target}: missing required vllm.auth.apiKeyRef entry")

if errors:
    for err in errors:
        sys.stderr.write(f"::error::check-vllm-secret-refs: {err}\n")
    sys.exit(1)

print("check-vllm-secret-refs: PASS (.chezmoidata YAML files and vllm.yaml auth values are op:// references only)")
PY
