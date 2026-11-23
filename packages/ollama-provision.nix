{ pkgs, kind }:
let
  model = import ./ollama-model.nix kind;
in
pkgs.writeShellApplication {
  name = "ollama-provision";
  runtimeInputs = [
    pkgs.curl
    pkgs.jq
  ];
  derivationArgs.postCheck = ''
    ${pkgs.bash}/bin/bash ${../tests/ollama-provision.sh} "$target" \
      ${pkgs.lib.escapeShellArgs [
        model.baseModel
        model.model
        (toString model.contextWindow)
      ]}
  '';
  text = ''
    base_model=${pkgs.lib.escapeShellArg model.baseModel}
    pi_model=${pkgs.lib.escapeShellArg model.model}
    context_window=${toString model.contextWindow}
  ''
  + builtins.readFile ../scripts/ollama-provision.sh;
}
