lib:
let
  snapshot = builtins.fromJSON (builtins.readFile ./openai-models.json);
in
map (model: model // { contextWindow = lib.min model.contextWindow 272000; }) snapshot.models
