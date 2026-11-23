kind:
let
  models = {
    nixos = {
      baseModel = "qwen3:4b-instruct";
      contextWindow = 32768;
    };
    darwin = {
      baseModel = "qwen3-coder:30b";
      contextWindow = 65536;
    };
  };
  inherit (models.${kind}) baseModel contextWindow;
in
{
  inherit baseModel contextWindow;
  model = "pi-${baseModel}-${toString (builtins.div contextWindow 1024)}k";
  maxTokens = 4096;
}
