#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
config="$repo_root/dot_config/fontconfig/fonts.conf"
scratch_root=${RUNNER_TEMP:-${XDG_RUNTIME_DIR:-"$HOME/.cache"}}
mkdir -p -- "$scratch_root"
scratch=$(mktemp -d "$scratch_root/fontconfig-korean.XXXXXX")

cleanup() {
  rm -rf -- "$scratch"
}
trap cleanup EXIT

fail() {
  printf 'fontconfig-korean: FAIL: %s\n' "$1" >&2
  exit 1
}

command -v fc-match >/dev/null 2>&1 || {
  if [[ -n ${CI:-} ]]; then
    fail 'fc-match is required in CI'
  fi
  printf 'fontconfig-korean: SKIP — fc-match is not installed\n'
  exit 0
}
[ -f "$config" ] || fail "managed fontconfig file not found at $config"

xdg_config="$scratch/xdg"
mkdir -p -- "$xdg_config/fontconfig"
cp -- "$config" "$xdg_config/fontconfig/fonts.conf"

resolve() {
  XDG_CONFIG_HOME="$xdg_config" env -u FONTCONFIG_FILE \
    fc-match -f '%{family[0]}|%{postscriptname}|%{file}' "$1"
}

for face in 'NotoSans Regular' 'NotoSans Medium' 'NotoSans Bold'; do
  resolved=$(resolve "$face") || fail "fc-match could not resolve $face"
  case "$resolved" in
    'Noto Sans|'*)
      fail "$face still resolves to the Latin-only Noto Sans family: $resolved"
      ;;
  esac
  printf 'fontconfig-korean: %s -> %s\n' "$face" "$resolved"
done

printf 'fontconfig-korean: PASS — local Noto Sans collisions are filtered\n'
