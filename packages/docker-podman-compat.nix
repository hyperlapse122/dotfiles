{ pkgs, podman }:
# `docker` as a link to `podman`, as NixOS virtualisation.podman.dockerCompat
# builds it.
pkgs.runCommand "docker-podman-compat-${podman.version}" { } ''
  mkdir -p $out/bin
  ln -s ${pkgs.lib.getExe podman} $out/bin/docker
''
