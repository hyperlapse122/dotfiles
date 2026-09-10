#!/usr/bin/env bash
set -euo pipefail

# Validates the reachability of the pinned QMK fork commit and toolchain image
# digest for the NuPhy Gem80 hostrgb firmware.
#
# TWO CHECKS.
#   1. Fork commit reachability: The pinned commit in .chezmoidata/firmware.yaml
#      must still be reachable from the declared branch in the remote fork
#      repository. Checking branch ancestry via the GitHub compare API ensures
#      the fetch path is intact — commit object existence alone is insufficient,
#      as an orphaned commit may survive temporarily after a force-push while the
#      build fetch path is already broken.
#   2. Toolchain image digest reachability: The digest-pinned container image
#      recorded in firmware/nuphy-gem80-hostrgb/dist/build-info.json must be
#      available from the container registry (ghcr.io).
#
# RUN PROFILE. Runs daily via .github/workflows/gem80-firmware-pins-daily.yml and
# can be dispatched manually. Lookup-only, non-mutating: does not clone the
# multi-GB QMK fork or pull container image layers.
#
# EVAL MODE. `--eval` replaces both live queries with supplied statuses so the
# judgment logic can be tested without network access (U5). The status overrides
# are reachable ONLY under `--eval`: a gate that could be silenced by an ambient
# environment variable would report healthy through the outage it exists to catch.
#
# FAILURE ISOLATION. Both checks run on every invocation. If one fails, the other
# is still checked so all broken dependencies are reported together, distinguishing
# fork commit unreachability from toolchain image unreachability.

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

validation_error() {
  printf 'check-gem80-firmware-pins: %s\n' "$1" >&2
  printf '::error::check-gem80-firmware-pins: %s\n' "$1"
}

validate_firmware_pins_inputs() {
  local fw_yaml="$1"
  local b_info="$2"

  if [ ! -f "$fw_yaml" ]; then
    validation_error "firmware manifest not found: $fw_yaml"
    return 1
  fi

  if [ ! -f "$b_info" ]; then
    validation_error "build info not found: $b_info"
    return 1
  fi

  local fork_source="" fork_ref="" fork_sha=""
  if command -v python3 >/dev/null 2>&1; then
    local fw_vals
    fw_vals=$(python3 -c '
import sys
try:
    import yaml
    with open(sys.argv[1], "r", encoding="utf-8") as f:
        data = yaml.safe_load(f) or {}
    fork = data.get("firmware", {}).get("gem80", {}).get("qmkFork", {})
    s = fork.get("source", "") or ""
    r = fork.get("ref", "") or ""
    h = fork.get("sha", "") or ""
    print(f"{s}\t{r}\t{h}")
except Exception:
    sys.exit(1)
' "$fw_yaml" 2>/dev/null || true)
    if [ -n "$fw_vals" ]; then
      IFS=$'\t' read -r fork_source fork_ref fork_sha <<<"$fw_vals"
    fi
  fi

  if [ -z "$fork_source" ] || [ -z "$fork_ref" ] || [ -z "$fork_sha" ]; then
    if command -v yq >/dev/null 2>&1; then
      local yq_vals
      yq_vals=$(yq -r '[.firmware.gem80.qmkFork.source // "", .firmware.gem80.qmkFork.ref // "", .firmware.gem80.qmkFork.sha // ""] | @tsv' "$fw_yaml" 2>/dev/null || true)
      if [ -n "$yq_vals" ]; then
        IFS=$'\t' read -r fork_source fork_ref fork_sha <<<"$yq_vals"
      fi
    fi
  fi

  if [ -z "$fork_source" ] || [ -z "$fork_ref" ] || [ -z "$fork_sha" ]; then
    local awk_vals
    awk_vals=$(awk '
      /^ *firmware:/ { in_fw=1; next }
      in_fw && /^ *gem80:/ { in_gem=1; next }
      in_gem && /^ *qmkFork:/ { in_fork=1; next }
      in_fork && /^ *[a-zA-Z0-9_-]+:/ && !/^ *(source|ref|sha):/ {
        if (match($0, /^ +/) < 6) { in_fork=0 }
      }
      in_fork && /^ *source:/ { sub(/^ *source:[ \t]*/, ""); gsub(/["\047]/, ""); src=$0 }
      in_fork && /^ *ref:/ { sub(/^ *ref:[ \t]*/, ""); gsub(/["\047]/, ""); ref=$0 }
      in_fork && /^ *sha:/ { sub(/^ *sha:[ \t]*/, ""); gsub(/["\047]/, ""); sha=$0 }
      END {
        if (src && ref && sha) {
          printf "%s\t%s\t%s\n", src, ref, sha
        }
      }
    ' "$fw_yaml")
    if [ -n "$awk_vals" ]; then
      IFS=$'\t' read -r fork_source fork_ref fork_sha <<<"$awk_vals"
    fi
  fi

  if [ -z "$fork_source" ] || [ -z "$fork_ref" ] || [ -z "$fork_sha" ]; then
    validation_error "firmware manifest missing required fields (firmware.gem80.qmkFork: source, ref, sha): $fw_yaml"
    return 1
  fi

  if ! [[ "$fork_sha" =~ ^[0-9a-f]{40}$ ]]; then
    validation_error "invalid fork commit sha format (expected 40-hex sha): $fork_sha"
    return 1
  fi

  if ! jq empty "$b_info" 2>/dev/null; then
    validation_error "build info is not valid JSON: $b_info"
    return 1
  fi

  local toolchain_img
  toolchain_img=$(jq -r '.toolchainImage // empty' "$b_info" 2>/dev/null || true)
  if [ -z "$toolchain_img" ]; then
    validation_error "build info missing toolchainImage: $b_info"
    return 1
  fi

  if ! [[ "$toolchain_img" =~ @sha256:[0-9a-f]{64}$ ]]; then
    validation_error "toolchainImage missing valid @sha256 digest: $toolchain_img"
    return 1
  fi

  printf '%s\t%s\t%s\t%s\n' "$fork_source" "$fork_ref" "$fork_sha" "$toolchain_img"
  return 0
}

query_github_compare() {
  local source="$1"
  local ref="$2"
  local sha="$3"
  local branch="${ref#refs/heads/}"
  local basehead="${sha}...${branch}"
  local url="https://api.github.com/repos/${source}/compare/${basehead}"

  local auth_headers=()
  local token="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
  if [ -n "$token" ]; then
    auth_headers=(-H "Authorization: Bearer $token")
  fi

  local resp_file
  resp_file=$(mktemp)
  local http_code
  http_code=$(curl -s -S -o "$resp_file" -w "%{http_code}" \
    -H "Accept: application/vnd.github+json" \
    "${auth_headers[@]}" \
    "$url" || echo "000")

  if [ "$http_code" = "200" ]; then
    local status behind_by
    status=$(jq -r '.status // empty' "$resp_file")
    behind_by=$(jq -r '.behind_by // 0' "$resp_file")
    rm -f "$resp_file"
    printf '%s\t%s\n' "$status" "$behind_by"
    return 0
  elif [ "$http_code" = "404" ]; then
    rm -f "$resp_file"
    printf '404\t0\n'
    return 0
  else
    local msg
    msg=$(jq -r '.message // empty' "$resp_file" 2>/dev/null || echo "HTTP $http_code")
    rm -f "$resp_file"
    printf 'error:%s\t0\n' "$msg"
    return 0
  fi
}

judge_commit_reachability() {
  local source="$1"
  local ref="$2"
  local sha="$3"
  local status="$4"
  local behind_by="${5:-0}"

  case "$status" in
    identical)
      return 0
      ;;
    ahead)
      if [ "$behind_by" -eq 0 ]; then
        return 0
      else
        printf 'fork commit %s is not an ancestor of %s in %s (branch is behind by %s commits)' \
          "$sha" "$ref" "$source" "$behind_by"
        return 1
      fi
      ;;
    behind)
      printf 'fork commit %s is not reachable from %s in %s (commit is ahead of branch)' \
        "$sha" "$ref" "$source"
      return 1
      ;;
    diverged)
      printf 'fork commit %s has diverged from %s in %s (branch is behind by %s commits)' \
        "$sha" "$ref" "$source" "$behind_by"
      return 1
      ;;
    404 | not_found)
      printf 'fork commit %s or ref %s not found in %s' \
        "$sha" "$ref" "$source"
      return 1
      ;;
    *)
      printf 'fork commit %s reachability query failed for %s in %s (%s)' \
        "$sha" "$ref" "$source" "$status"
      return 1
      ;;
  esac
}

query_image_registry() {
  local image="$1"

  # Fast path: try podman manifest inspect if available
  if command -v podman >/dev/null 2>&1; then
    if podman manifest inspect "$image" >/dev/null 2>&1; then
      printf 'ok\n'
      return 0
    fi
  elif command -v docker >/dev/null 2>&1; then
    if docker manifest inspect "$image" >/dev/null 2>&1; then
      printf 'ok\n'
      return 0
    fi
  fi

  # Fallback to direct OCI Registry HTTP API query via curl
  local ref="${image#*@}"
  local repo_full="${image%@*}"
  local registry="${repo_full%%/*}"
  local repo="${repo_full#*/}"

  local accept_headers=(
    -H "Accept: application/vnd.oci.image.index.v1+json"
    -H "Accept: application/vnd.oci.image.manifest.v1+json"
    -H "Accept: application/vnd.docker.distribution.manifest.list.v2+json"
    -H "Accept: application/vnd.docker.distribution.manifest.v2+json"
  )

  local manifest_url="https://${registry}/v2/${repo}/manifests/${ref}"
  local headers_file
  headers_file=$(mktemp)
  local http_code
  http_code=$(curl -s -S -o /dev/null -D "$headers_file" -w "%{http_code}" "${accept_headers[@]}" "$manifest_url" || echo "000")

  if [ "$http_code" = "200" ]; then
    rm -f "$headers_file"
    printf 'ok\n'
    return 0
  elif [ "$http_code" = "401" ]; then
    local auth_header
    auth_header=$(grep -i '^www-authenticate:' "$headers_file" | tr -d '\r' | head -n 1)
    rm -f "$headers_file"

    if [[ "$auth_header" =~ realm=\"([^\"]+)\" ]]; then
      local realm="${BASH_REMATCH[1]}"
      local service=""
      local scope=""
      if [[ "$auth_header" =~ service=\"([^\"]+)\" ]]; then
        service="${BASH_REMATCH[1]}"
      fi
      if [[ "$auth_header" =~ scope=\"([^\"]+)\" ]]; then
        scope="${BASH_REMATCH[1]}"
      else
        scope="repository:${repo}:pull"
      fi

      local token_url="${realm}?"
      [ -n "$service" ] && token_url="${token_url}service=${service}&"
      [ -n "$scope" ] && token_url="${token_url}scope=${scope}"

      local token_json
      token_json=$(curl -s -S "$token_url" || echo "{}")
      local token
      token=$(echo "$token_json" | jq -r '.token // .access_token // empty')

      if [ -n "$token" ]; then
        http_code=$(curl -s -S -o /dev/null -w "%{http_code}" \
          -H "Authorization: Bearer $token" \
          "${accept_headers[@]}" "$manifest_url" || echo "000")
        if [ "$http_code" = "200" ]; then
          printf 'ok\n'
          return 0
        fi
      fi
    fi
  else
    rm -f "$headers_file"
  fi

  printf 'error:HTTP_%s\n' "$http_code"
  return 0
}

judge_image_reachability() {
  local image="$1"
  local status="$2"

  case "$status" in
    ok | 200 | success)
      return 0
      ;;
    *)
      printf 'toolchain image %s is not reachable in registry (%s)' "$image" "$status"
      return 1
      ;;
  esac
}

judge_firmware_pins() {
  local fork_source="$1"
  local fork_ref="$2"
  local fork_sha="$3"
  local commit_status="$4"
  local behind_by="$5"
  local toolchain_image="$6"
  local image_status="$7"

  local errors=()

  local commit_err
  if ! commit_err=$(judge_commit_reachability "$fork_source" "$fork_ref" "$fork_sha" "$commit_status" "$behind_by"); then
    errors+=("$commit_err")
  fi

  local img_err
  if ! img_err=$(judge_image_reachability "$toolchain_image" "$image_status"); then
    errors+=("$img_err")
  fi

  if [ ${#errors[@]} -gt 0 ]; then
    for err in "${errors[@]}"; do
      printf 'check-gem80-firmware-pins: %s\n' "$err" >&2
      printf '::error::check-gem80-firmware-pins: %s\n' "$err"
    done
    return 1
  fi

  printf 'check-gem80-firmware-pins: ok\n'
  return 0
}

show_usage() {
  cat <<'EOF'
Usage: check-gem80-firmware-pins.sh [options] [firmware_yaml] [build_info_json]

Validates reachability of the pinned QMK fork commit and toolchain image digest.

Options:
  --firmware-yaml <path>     Path to firmware.yaml (default: .chezmoidata/firmware.yaml)
  --build-info <path>        Path to build-info.json (default: firmware/nuphy-gem80-hostrgb/dist/build-info.json)
  --eval                     Judge supplied statuses instead of querying; requires the three below
  --commit-status <status>   Eval only: GitHub compare status (e.g. identical, ahead, diverged, 404)
  --behind-by <n>            Eval only: behind_by commit count (default: 0)
  --image-status <status>    Eval only: image reachability status (e.g. ok, error:HTTP_404)
  -h, --help                 Show this help message
EOF
}

main() {
  local fw_yaml=""
  local b_info=""
  local eval_mode=false
  local commit_status=""
  local behind_by="0"
  local image_status=""

  local positional=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --firmware-yaml)
        fw_yaml="$2"
        shift 2
        ;;
      --build-info)
        b_info="$2"
        shift 2
        ;;
      --eval)
        eval_mode=true
        shift
        ;;
      --commit-status)
        commit_status="$2"
        shift 2
        ;;
      --behind-by)
        behind_by="$2"
        shift 2
        ;;
      --image-status)
        image_status="$2"
        shift 2
        ;;
      -h|--help)
        show_usage
        exit 0
        ;;
      *)
        positional+=("$1")
        shift
        ;;
    esac
  done

  if [ -z "$fw_yaml" ] && [ ${#positional[@]} -ge 1 ]; then
    fw_yaml="${positional[0]}"
  fi
  if [ -z "$b_info" ] && [ ${#positional[@]} -ge 2 ]; then
    b_info="${positional[1]}"
  fi

  fw_yaml="${fw_yaml:-$repo_root/.chezmoidata/firmware.yaml}"
  b_info="${b_info:-$repo_root/firmware/nuphy-gem80-hostrgb/dist/build-info.json}"

  if [ "$eval_mode" = true ]; then
    if [ -z "$commit_status" ] || [ -z "$image_status" ]; then
      validation_error "--eval requires --commit-status and --image-status"
      exit 1
    fi
  elif [ -n "$commit_status" ] || [ -n "$image_status" ]; then
    validation_error "--commit-status and --image-status are only valid with --eval"
    exit 1
  fi

  local parsed
  if ! parsed=$(validate_firmware_pins_inputs "$fw_yaml" "$b_info"); then
    exit 1
  fi

  local fork_source fork_ref fork_sha toolchain_image
  IFS=$'\t' read -r fork_source fork_ref fork_sha toolchain_image <<<"$parsed"

  if [ "$eval_mode" = false ]; then
    local cmp_result
    cmp_result=$(query_github_compare "$fork_source" "$fork_ref" "$fork_sha")
    IFS=$'\t' read -r commit_status behind_by <<<"$cmp_result"
    image_status=$(query_image_registry "$toolchain_image")
  fi

  judge_firmware_pins "$fork_source" "$fork_ref" "$fork_sha" "$commit_status" "$behind_by" "$toolchain_image" "$image_status" || exit 1
  exit 0
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
