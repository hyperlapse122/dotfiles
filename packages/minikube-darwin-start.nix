{ pkgs }:
pkgs.writeShellApplication {
  name = "minikube-darwin-start";
  # timeout; macOS ships none.
  runtimeInputs = [ pkgs.coreutils ];
  text = builtins.readFile ../scripts/minikube-darwin-start;
}
