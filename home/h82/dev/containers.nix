{
  config,
  lib,
  pkgs,
  ...
}:
let
  credHelpers = {
    "docker.io" = "sops";
    "ghcr.io" = "sops";
    "registry.gitlab.com" = "sops";
    "registry.jpi.app" = "sops";
  };
  initialAuth = builtins.toJSON { inherit credHelpers; };
  authFile = "${config.home.homeDirectory}/.config/containers/auth.json";
  linuxSessionVariables = {
    DOCKER_HOST = "unix://\${XDG_RUNTIME_DIR}/podman/podman.sock";
    # Ryuk needs a privileged container to manage the rootless Podman socket.
    TESTCONTAINERS_RYUK_CONTAINER_PRIVILEGED = "true";
    TESTCONTAINERS_RYUK_PRIVILEGED = "true";
  };

in
lib.mkMerge [
  (lib.mkIf (config.my.kind != "darwin") {
    home.sessionVariables.REGISTRY_AUTH_FILE = authFile;

    home.activation.containersAuth = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
          AUTH_DIR="$HOME/.config/containers"
          AUTH_FILE="$AUTH_DIR/auth.json"
          if [ ! -e "$AUTH_FILE" ] && [ ! -L "$AUTH_FILE" ]; then
            run mkdir -p "$AUTH_DIR"
            run chmod 0700 "$AUTH_DIR"
            if [[ -v DRY_RUN ]]; then
              echo "Creating $AUTH_FILE with initial credHelpers"
            else
              cat <<'EOF' > "$AUTH_FILE"
      ${initialAuth}
      EOF
              chmod 0600 "$AUTH_FILE"
            fi
          fi
    '';
  })

  # Rootless Podman on the host is the container runtime on NixOS and Linux
  # hosts.
  (lib.mkIf (config.my.kind != "darwin") {
    home.sessionVariables = linuxSessionVariables;

    systemd.user.sessionVariables = linuxSessionVariables // {
      REGISTRY_AUTH_FILE = authFile;
    };

    xdg.configFile."containers/registries.conf.d/10-unqualified-search.conf".text = ''
      unqualified-search-registries = ["docker.io"]
    '';
  })

]
