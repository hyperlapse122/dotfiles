{ pkgs }:
pkgs.writeShellApplication {
  name = "podman-machine-resources";
  text = builtins.readFile ../scripts/podman-machine-resources;
}
