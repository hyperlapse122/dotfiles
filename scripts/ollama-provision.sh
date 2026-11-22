# The service manager retries if Ollama or the registry is unavailable.
api() {
    local endpoint=$1
    shift
    curl --disable --silent --show-error --fail-with-body --noproxy '*' \
        --connect-timeout 5 "http://127.0.0.1:11434/api/$endpoint" "$@"
}

models=$(api tags)
has_model() {
    jq -e --arg model "$1" 'any(.models[]; .name == $model)' <<< "$models" >/dev/null
}

if has_model "$pi_model"; then
    exit 0
fi

if ! has_model "$base_model"; then
    pull=$(jq -nc --arg model "$base_model" '{model: $model, stream: false}')
    api pull --json "$pull" | jq -e '.status == "success"' >/dev/null
fi

# Ollama reuses the downloaded weight blobs. The model parameter sets the
# actual serving window for Pi's OpenAI-compatible requests on either host.
create=$(jq -nc --arg model "$pi_model" --arg base "$base_model" --argjson context "$context_window" \
    '{model: $model, from: $base, parameters: {num_ctx: $context}, stream: false}')
api create --json "$create" | jq -e '.status == "success"' >/dev/null
