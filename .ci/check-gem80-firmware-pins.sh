#!/usr/bin/env bash
set -euo pipefail

# Validates the reachability of the pinned QMK fork commit and toolchain image
# digest for the NuPhy Gem80 hostrgb firmware.
#
# TWO CHECKS.
#   1. Fork commit reachability: The pinned commit in .chezmoidata/firmware.yaml
#      must still be an ancestor of the declared branch in the remote fork.
#      Commit object existence alone is insufficient — an orphaned commit can
#      survive for a while after a force-push while the build's fetch is already
#      broken.
#   2. Toolchain image digest reachability: the digest-pinned container image
#      must still be served by its registry.
#
# WHAT THIS DOES NOT WATCH. The build also fetches three submodules
# (lib/chibios, lib/chibios-contrib, lib/printf) from repositories this gate
# never queries. If one of those disappears, this gate stays green and only the
# weekly rebuild notices, so the blind spot is up to a week wide. That split is
# deliberate — resolving submodule pins needs the fork's tree, which is the
# clone this gate exists to avoid — but do not read a green run here as "the
# whole build path is fine".
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

# shellcheck source=.ci/lib/gem80-firmware-data.sh
source "$repo_root/.ci/lib/gem80-firmware-data.sh"

# Without these a stalled TLS handshake blocks on the kernel socket timeout,
# which outlives the workflow's own timeout and reports as an ambiguous job
# cancellation rather than an unreachable dependency.
CURL_TIMEOUTS=(--connect-timeout 10 --max-time 30)

validation_error() {
  printf 'check-gem80-firmware-pins: %s\n' "$1" >&2
  printf '::error::check-gem80-firmware-pins: %s\n' "$1"
}

# The build runs the image baked into the rendered gem80-firmware command, while
# this gate reads the one the last build recorded. They are separate values, so
# bumping the command without rebuilding would leave this gate vouching for an
# image the build no longer uses.
assert_image_matches_command() {
  local recorded="$1"
  local template="$repo_root/dot_local/share/chezmoi-command-sources/executable_gem80-firmware.tmpl"

  [ -f "$template" ] || {
    validation_error "gem80-firmware template not found: $template"
    return 1
  }

  local command_image
  command_image=$(sed -n -E 's/^IMAGE="([^"]+)".*/\1/p' "$template" | head -n 1)
  if ! [[ $command_image =~ @sha256:[0-9a-f]{64}$ ]]; then
    validation_error "could not read a digest-pinned IMAGE from $template"
    return 1
  fi

  if [ "$command_image" != "$recorded" ]; then
    validation_error "toolchain image drift: the build command uses $command_image but the build record says $recorded"
    return 1
  fi
  return 0
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

  local fork_source fork_ref fork_sha
  fork_source=$(gem80_firmware_yaml_get "$fw_yaml" firmware.gem80.qmkFork.source || true)
  fork_ref=$(gem80_firmware_yaml_get "$fw_yaml" firmware.gem80.qmkFork.ref || true)
  fork_sha=$(gem80_firmware_yaml_get "$fw_yaml" firmware.gem80.qmkFork.sha || true)

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
  # curl -w already writes 000 when it cannot connect, so an `|| echo 000` here
  # would emit it twice and the caller would read a two-line status.
  http_code=$(curl -sS "${CURL_TIMEOUTS[@]}" -o "$resp_file" -w "%{http_code}" \
    -H "Accept: application/vnd.github+json" \
    "${auth_headers[@]}" \
    "$url") || true
  http_code="${http_code##*$'\n'}"
  http_code="${http_code:-000}"

  if [ "$http_code" = "200" ]; then
    # A captive portal or proxy can answer 200 with HTML. Unparsed output is an
    # error to report, never a status to act on.
    local parsed
    if ! parsed=$(jq -r '[.status // "", .behind_by // 0] | @tsv' "$resp_file" 2>/dev/null); then
      rm -f "$resp_file"
      printf 'error:malformed JSON in a 200 response\t0\n'
      return 0
    fi
    rm -f "$resp_file"
    printf '%s\n' "$parsed"
    return 0
  elif [ "$http_code" = "404" ]; then
    rm -f "$resp_file"
    printf '404\t0\n'
    return 0
  else
    local msg
    msg=$(jq -r '.message // empty' "$resp_file" 2>/dev/null || true)
    [ -n "$msg" ] || msg="HTTP $http_code"
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

  # No container-tool fast path. `podman manifest inspect` and its docker shim
  # answer from local image storage, so on any host that has ever built this
  # firmware the digest resolves without a single packet reaching the registry —
  # and the check would report healthy for an image ghcr no longer serves. The
  # registry HTTP API is the only thing that actually answers the question.
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
  # shellcheck disable=SC2064
  trap "rm -f -- '$headers_file'" RETURN

  local http_code
  http_code=$(curl -sS "${CURL_TIMEOUTS[@]}" -o /dev/null -D "$headers_file" -w "%{http_code}" \
    "${accept_headers[@]}" "$manifest_url") || true
  http_code="${http_code##*$'\n'}"
  http_code="${http_code:-000}"

  if [ "$http_code" = "200" ]; then
    printf 'ok\n'
    return 0
  fi

  if [ "$http_code" != "401" ]; then
    printf 'error:HTTP_%s\n' "$http_code"
    return 0
  fi

  # Anonymous pull: the registry answers 401 with the token endpoint to use.
  local auth_header
  auth_header=$(grep -i '^www-authenticate:' "$headers_file" | tr -d '\r' | head -n 1 || true)
  if [[ ! $auth_header =~ realm=\"([^\"]+)\" ]]; then
    printf 'error:HTTP_401_no_auth_challenge\n'
    return 0
  fi
  local realm="${BASH_REMATCH[1]}"

  local service="" scope=""
  [[ $auth_header =~ service=\"([^\"]+)\" ]] && service="${BASH_REMATCH[1]}"
  if [[ $auth_header =~ scope=\"([^\"]+)\" ]]; then
    scope="${BASH_REMATCH[1]}"
  else
    scope="repository:${repo}:pull"
  fi

  local token_url="${realm}?"
  [ -n "$service" ] && token_url="${token_url}service=${service}&"
  token_url="${token_url}scope=${scope}"

  local token_json token
  token_json=$(curl -sS "${CURL_TIMEOUTS[@]}" "$token_url") || token_json=''
  # A gateway can answer the token endpoint with an HTML error page, which jq
  # cannot parse; an empty token then falls through to the failure below.
  token=$(printf '%s' "$token_json" | jq -r '.token // .access_token // empty' 2>/dev/null || true)
  if [ -z "$token" ]; then
    printf 'error:HTTP_401_token_unavailable\n'
    return 0
  fi

  http_code=$(curl -sS "${CURL_TIMEOUTS[@]}" -o /dev/null -w "%{http_code}" \
    -H "Authorization: Bearer $token" \
    "${accept_headers[@]}" "$manifest_url") || true
  http_code="${http_code##*$'\n'}"
  http_code="${http_code:-000}"

  if [ "$http_code" = "200" ]; then
    printf 'ok\n'
    return 0
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
      validation_error "$err"
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
    assert_image_matches_command "$toolchain_image" || exit 1

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
