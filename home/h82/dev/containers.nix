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

  # The machine Podman's default connection names, so plain `podman` and
  # minikube reach it without a --connection.
  machineName = "podman-machine-default";
  podman = config.services.podman.package;
  resources = import ../../../packages/podman-machine-resources.nix { inherit pkgs; };
  machine = {
    memory = 8192;
    cpus = 4;
  };
  # Podman 5 forwards the machine's API to this socket under the per-user
  # temporary directory; nixpkgs builds no podman-mac-helper to link it to
  # /var/run/docker.sock.
  apiSocket = "podman/${machineName}-api.sock";
  # Ryuk mounts the Docker socket from inside the VM, where Podman links it.
  vmDockerSocket = "/var/run/docker.sock";
in
lib.mkMerge [
  {
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
  }

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

  # A macOS host runs one rootful Podman machine on libkrun, which its
  # watchdog agent starts at login. The module's registries.conf already
  # searches docker.io, and a store-linked drop-in would dangle inside the VM,
  # which mounts ~/.config/containers.
  (lib.mkIf (config.my.kind == "darwin") {
    services.podman = {
      enable = true;
      # The module merges its all-null default machine over a same-named
      # entry, which would drop --rootful, --memory and --cpus from init.
      useDefaultMachine = false;
      machines.${machineName} = machine // {
        # minikube's macOS driver uses the rootful connection, and rootless
        # Ryuk would need its own flags.
        rootful = true;
      };
      # Podman 5.8 defaults to applehv, which never returns freed guest
      # memory to macOS. containers.conf reaches every `podman machine` call:
      # activation, the watchdog, and the shell.
      settings.containers.machine.provider = "libkrun";
    };

    # Podman starts krunkit and gvproxy in the watchdog's process group, so
    # launchd would kill the VM whenever an apply reloads the agent; the
    # module's Background type would also throttle every container.
    launchd.agents."podman-machine-${machineName}".config = {
      AbandonProcessGroup = true;
      ProcessType = lib.mkForce "Interactive";
    };

    # The module applies memory and CPUs only when it creates the machine.
    # The watchdog restarts the machine once the helper has stopped it.
    # Activation runs under sudo, which drops TMPDIR, and Podman keeps the
    # running machine's state under the per-user temporary directory the
    # watchdog's launchd job sees, so the helper is given that directory.
    home.activation.podmanMachineResources = lib.hm.dag.entryAfter [ "podmanMachines" ] ''
      if [[ -v DRY_RUN ]]; then
        echo "Reconciling ${machineName} to ${toString machine.memory} MiB and ${toString machine.cpus} CPUs"
      else
        TMPDIR=$(/usr/bin/getconf DARWIN_USER_TEMP_DIR) ${lib.getExe resources} ${lib.getExe podman} ${machineName} ${toString machine.memory} ${toString machine.cpus}
      fi
    '';

    home.sessionVariables = {
      DOCKER_HOST = "unix://\${TMPDIR:-/tmp/}${apiSocket}";
      TESTCONTAINERS_DOCKER_SOCKET_OVERRIDE = vmDockerSocket;
    };

    # Apps launched from Finder or the Dock never read hm-session-vars.sh.
    launchd.agents.container-environment = {
      enable = true;
      config = {
        ProgramArguments = [
          "/bin/sh"
          "-c"
          ''
            tmp=$(/usr/bin/getconf DARWIN_USER_TEMP_DIR)
            /bin/launchctl setenv DOCKER_HOST "unix://''${tmp}${apiSocket}"
            /bin/launchctl setenv TESTCONTAINERS_DOCKER_SOCKET_OVERRIDE ${vmDockerSocket}
          ''
        ];
        RunAtLoad = true;
      };
    };

    # The darwin counterpart of NixOS dockerCompat: `docker` is Podman, so it
    # reads the same auth.json credential helpers.
    home.packages = [
      (import ../../../packages/docker-podman-compat.nix { inherit pkgs podman; })
    ];
  })
]
