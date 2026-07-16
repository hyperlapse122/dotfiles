#!/bin/sh
# Shared CLIProxyAPI semantic verifier. Source from the rendered reconciler or
# run with CPA_SMOKE_MAIN=1 CPA_EXPECTED_PID=<pid> and the CPA_* paths set.
set -eu

cpa_fail() {
  printf '%s\n' "cli-proxy-api smoke: $*" >&2
  return 1
}

cpa_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    cpa_sha_output=$(sha256sum "$1") || return 1
  else
    cpa_sha_output=$(shasum -a 256 "$1") || return 1
  fi
  cpa_sha_digest=${cpa_sha_output%%[[:space:]]*}
  printf '%s' "$cpa_sha_digest" | grep -Eq '^[0-9a-f]{64}$' || return 1
  printf '%s\n' "$cpa_sha_digest"
}

cpa_realpath() {
  cpa_path=$1
  while [ -L "$cpa_path" ]; do
    cpa_link=$(readlink "$cpa_path")
    case $cpa_link in
      /*) cpa_path=$cpa_link ;;
      *) cpa_path=$(dirname "$cpa_path")/$cpa_link ;;
    esac
  done
  cpa_dir=$(unset CDPATH; cd -- "$(dirname "$cpa_path")" && pwd -P)
  printf '%s/%s\n' "$cpa_dir" "$(basename "$cpa_path")"
}

cpa_http_status() {
  curl --noproxy '*' -sS --max-time 3 -o "$2" -w '%{http_code}' "$1"
}

cpa_directory_is_empty() {
  for cpa_entry in "$1"/* "$1"/.[!.]* "$1"/..?*; do
    [ ! -e "$cpa_entry" ] && [ ! -L "$cpa_entry" ] || return 1
  done
  return 0
}

cpa_smoke_cleanup() {
  case ${CPA_SMOKE_TMP:-} in
    "$CPA_WORK_DIR"/smoke.*) rm -rf "$CPA_SMOKE_TMP" ;;
    "") : ;;
    *) cpa_fail "refusing to remove smoke state outside the managed work directory" ;;
  esac
}

cpa_expect_404() {
  cpa_status=$(cpa_http_status "$1" "$CPA_SMOKE_TMP/route-body") || {
    cpa_fail "transport failure for $1"
    return 1
  }
  [ "$cpa_status" = 404 ] || {
    cpa_fail "$1 returned HTTP $cpa_status, expected 404"
    return 1
  }
}

cpa_listener_owned() {
  cpa_pid=$1
  kill -0 "$cpa_pid" 2>/dev/null || {
    cpa_fail "expected PID $cpa_pid is not running"
    return 1
  }
  command -v lsof >/dev/null 2>&1 || {
    cpa_fail "lsof is required for listener ownership checks"
    return 1
  }
  cpa_rows=$(lsof -nP -iTCP:8317 -sTCP:LISTEN 2>/dev/null | awk 'NR > 1 { print $2 "|" $9 }')
  cpa_row_count=$(printf '%s\n' "$cpa_rows" | awk 'NF { count++ } END { print count+0 }')
  [ "$cpa_row_count" -ne 0 ] || return 2
  [ "$cpa_row_count" -eq 1 ] || {
    cpa_fail "port 8317 must have exactly one listening socket"
    return 1
  }
  [ "$cpa_rows" = "$cpa_pid|127.0.0.1:8317" ] || {
    cpa_fail "PID $cpa_pid is not the sole 127.0.0.1:8317 listener"
    return 1
  }

  cpa_actual_exe=$(lsof -a -p "$cpa_pid" -d txt -Fn 2>/dev/null | awk '/^n/ { print substr($0, 2); exit }')
  cpa_expected_exe=$(cpa_realpath "$CPA_ACTIVE_BINARY") || return 1
  [ "$cpa_actual_exe" = "$cpa_expected_exe" ] || {
    cpa_fail "listener executable does not match the active candidate"
    return 1
  }
}

cpa_smoke_checks() {
  cpa_expected_pid=$1
  : "${CPA_ACTIVE_BINARY:?CPA_ACTIVE_BINARY is required}"
  : "${CPA_CONFIG:?CPA_CONFIG is required}"
  : "${CPA_AUTH_DIR:?CPA_AUTH_DIR is required}"
  : "${CPA_WORK_DIR:?CPA_WORK_DIR is required}"
  : "${CPA_EXPECTED_CONFIG_SHA256:?CPA_EXPECTED_CONFIG_SHA256 is required}"
  cpa_jq=${CPA_JQ:-jq}
  command -v "$cpa_jq" >/dev/null 2>&1 || {
    cpa_fail "jq is required for semantic JSON checks"
    return 1
  }

  kill -0 "$cpa_expected_pid" 2>/dev/null || {
    cpa_fail "expected PID $cpa_expected_pid is not running"
    return 1
  }
  [ -f "$CPA_CONFIG" ] && [ ! -L "$CPA_CONFIG" ] || {
    cpa_fail "config is not a regular file"
    return 1
  }
  grep -qx 'commercial-mode: true' "$CPA_CONFIG" || {
    cpa_fail "commercial mode must suppress request-error logging"
    return 1
  }
  cpa_before_hash=$(cpa_sha256 "$CPA_CONFIG") || {
    cpa_fail "could not hash managed config before readiness"
    return 1
  }
  [ "$cpa_before_hash" = "$CPA_EXPECTED_CONFIG_SHA256" ] || {
    cpa_fail "managed config changed before readiness"
    return 1
  }
  cpa_listener_owned "$cpa_expected_pid" || return 1

  cpa_health_body=$CPA_SMOKE_TMP/health.json
  cpa_status=$(cpa_http_status http://127.0.0.1:8317/healthz "$cpa_health_body") || {
    cpa_fail "health transport failure"
    return 1
  }
  [ "$cpa_status" = 200 ] || {
    cpa_fail "health returned HTTP $cpa_status"
    return 1
  }
  "$cpa_jq" -e '.status == "ok"' "$cpa_health_body" >/dev/null 2>&1 || {
    cpa_fail "health response is not the expected JSON"
    return 1
  }

  cpa_canary=${CPA_SMOKE_CANARY:-cpa-smoke-$cpa_expected_pid-$(date +%s)}
  [ -n "$cpa_canary" ] || {
    cpa_fail "request canary must not be empty"
    return 1
  }
  cpa_provider_body=$CPA_SMOKE_TMP/provider.json
  cpa_status=$(curl --noproxy '*' -sS --max-time 5 -o "$cpa_provider_body" -w '%{http_code}' \
    -H 'Content-Type: application/json' \
    --data "{\"agent\":\"cli-proxy-api-readiness\",\"input\":\"$cpa_canary\",\"stream\":false}" \
    http://127.0.0.1:8317/v1beta/interactions) || {
    cpa_fail "provider-routable request transport failure"
    return 1
  }
  [ "$cpa_status" = 503 ] || {
    cpa_fail "provider-routable request returned HTTP $cpa_status, expected no-auth 503"
    return 1
  }
  "$cpa_jq" -e '.error.type == "server_error" and .error.code == "internal_server_error" and (.error.message | ascii_downcase | contains("no auth available"))' "$cpa_provider_body" >/dev/null 2>&1 || {
    cpa_fail "provider-routable response is not the expected no-auth JSON"
    return 1
  }

  cpa_expect_404 http://127.0.0.1:8317/v0/management/config || return 1
  cpa_expect_404 http://127.0.0.1:8317/management.html || return 1
  cpa_expect_404 http://127.0.0.1:8317/v0/resource/plugins/example || return 1

  cpa_config_dir=$(dirname "$CPA_CONFIG")
  [ ! -e "$cpa_config_dir/static/management.html" ] || {
    cpa_fail "management panel artifact exists"
    return 1
  }
  [ ! -e "$CPA_WORK_DIR/plugins" ] || {
    cpa_fail "plugin artifact directory exists"
    return 1
  }
  cpa_directory_is_empty "$CPA_AUTH_DIR" || {
    cpa_fail "auth state appeared during readiness"
    return 1
  }
  cpa_after_hash=$(cpa_sha256 "$CPA_CONFIG") || {
    cpa_fail "could not hash managed config after readiness"
    return 1
  }
  [ "$CPA_EXPECTED_CONFIG_SHA256" = "$cpa_after_hash" ] || {
    cpa_fail "managed config mutated during startup or readiness"
    return 1
  }

  # Remove verifier-owned response files before checking whether the request
  # canary escaped into application state or supervisor output.
  cpa_smoke_cleanup || return 1
  for cpa_scan_root in "$CPA_AUTH_DIR" "$CPA_WORK_DIR" "$cpa_config_dir"; do
    if [ -d "$cpa_scan_root" ] && grep -R -F -l -- "$cpa_canary" "$cpa_scan_root" >/dev/null 2>&1; then
      cpa_fail "request canary persisted under managed state"
      return 1
    fi
  done
  if [ -n "${CPA_LOG_FILE:-}" ] && [ -f "$CPA_LOG_FILE" ] && grep -F -q -- "$cpa_canary" "$CPA_LOG_FILE"; then
    cpa_fail "request canary appeared in supervisor output"
    return 1
  fi

  # Close the port-handoff race: the same PID/executable must still own the sole
  # loopback listener after every HTTP and persistence assertion succeeds.
  cpa_listener_owned "$cpa_expected_pid" || return 1
}

cpa_smoke() {
  cpa_expected_pid=${1:?expected pid required}
  [ -d "$CPA_WORK_DIR" ] && [ ! -L "$CPA_WORK_DIR" ] || {
    cpa_fail "working directory is missing or unsafe"
    return 1
  }
  # Never trust an inherited cleanup path. The verifier owns only this child of
  # the already-validated managed work directory.
  CPA_SMOKE_TMP=$CPA_WORK_DIR/smoke.$cpa_expected_pid.$$
  [ ! -L "$CPA_SMOKE_TMP" ] || {
    cpa_fail "smoke directory must not be a symlink"
    return 1
  }
  mkdir -m 700 "$CPA_SMOKE_TMP" 2>/dev/null || {
    [ -d "$CPA_SMOKE_TMP" ] && chmod 700 "$CPA_SMOKE_TMP"
  }
  cpa_smoke_max=${CPA_SMOKE_MAX_ATTEMPTS:-10}
  case $cpa_smoke_max in *[!0-9]*|0) cpa_smoke_max=10 ;; esac
  cpa_attempt=0
  while [ "$cpa_attempt" -lt "$cpa_smoke_max" ]; do
    if cpa_listener_owned "$cpa_expected_pid"; then
      break
    else
      cpa_result=$?
      [ "$cpa_result" -eq 2 ] || {
        cpa_smoke_cleanup || true
        return "$cpa_result"
      }
    fi
    kill -0 "$cpa_expected_pid" 2>/dev/null || {
      cpa_smoke_cleanup || true
      cpa_fail "expected PID $cpa_expected_pid exited before binding"
      return 1
    }
    cpa_attempt=$((cpa_attempt + 1))
    sleep 1
  done
  [ "$cpa_attempt" -lt "$cpa_smoke_max" ] || {
    cpa_smoke_cleanup || true
    cpa_fail "timed out waiting for 127.0.0.1:8317"
    return 1
  }

  if cpa_smoke_checks "$cpa_expected_pid"; then
    cpa_smoke_cleanup || return 1
    return 0
  else
    cpa_result=$?
    cpa_smoke_cleanup || true
    return "$cpa_result"
  fi
}

if [ "${CPA_SMOKE_MAIN:-0}" = 1 ]; then
  cpa_smoke "${CPA_EXPECTED_PID:?CPA_EXPECTED_PID is required}"
fi
