#!/usr/bin/env bash
set -euo pipefail

program=$1
export base=$2 local_model=$3 window=$4
export calls="$TMPDIR/ollama-requests" stage=missing

# Exercise the installed helper without a registry or a listening Ollama.
curl() {
    [[ $1 == --disable && " $* " == *" --noproxy * "* ]] || return 2
    local endpoint
    for endpoint in "$@"; do
        [[ $endpoint == http://127.0.0.1:11434/api/* ]] && break
    done
    endpoint=${endpoint##*/}
    echo "$endpoint" >> "$calls"
    case $endpoint in
        tags)
            case $stage in
                cached) jq -n --arg id "$local_model" '{models:[{name:$id}]}' ;;
                downloaded) jq -n --arg id "$base" '{models:[{name:$id}]}' ;;
                *) echo '{"models":[]}' ;;
            esac ;;
        pull)
            [[ $stage != interrupted ]] || return 22
            jq -e --arg id "$base" '.model == $id and .stream == false' <<< "${!#}" >/dev/null || return 1
            echo '{"status":"success"}' ;;
        create)
            jq -e --arg id "$local_model" --arg base "$base" --argjson n "$window" \
                '.model == $id and .from == $base and .parameters.num_ctx == $n and .stream == false' \
                <<< "${!#}" >/dev/null || return 1
            echo '{"status":"success"}' ;;
        *) return 2 ;;
    esac
}
export -f curl

stage=interrupted
if "$program"; then exit 1; fi
[[ $(cat "$calls") == $'tags\npull' ]]
for stage in missing downloaded cached; do
    : > "$calls"
    "$program"
    case $stage in
        missing) [[ $(cat "$calls") == $'tags\npull\ncreate' ]] ;;
        downloaded) [[ $(cat "$calls") == $'tags\ncreate' ]] ;;
        cached) [[ $(cat "$calls") == tags ]] ;;
    esac
done
