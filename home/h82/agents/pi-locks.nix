let
  read = file: builtins.fromJSON (builtins.readFile file);
  snapshot = provider: file: {
    inherit provider;
    models = (read file).data;
  };
in
(read ./pi-model-lock.json)
// {
  openaiModelLocks = snapshot "openai" ./pi-openai-model-lock.json;
  anthropicModelLocks = snapshot "anthropic" ./pi-anthropic-model-lock.json;
}
