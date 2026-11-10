{
  config,
  lib,
  pkgs,
  ...
}:
let
  podman = config.services.podman.package;
  start = import ../../../packages/minikube-darwin-start.nix { inherit pkgs; };
  logFile = "${config.home.homeDirectory}/Library/Logs/minikube.log";
  # How long the agent waits for the Podman machine to answer, polling every
  # few seconds, before it fails and launchd retries it.
  startTimeout = 300;
  pollInterval = 5;
  # Half of the Podman machine's 8 GiB and 4 CPUs in containers.nix, so
  # containers outside the cluster keep headroom.
  node = {
    memory = 4096;
    cpus = 2;
  };
in
lib.mkMerge [
  {
    # The minikube package links its own bin/kubectl to minikube, which
    # downloads a kubectl on first use; the real kubectl takes priority. Each
    # package installs its zsh completion into share/zsh/site-functions.
    home.packages = [
      (lib.hiPrio pkgs.kubectl)
      pkgs.kubernetes-helm
      pkgs.minikube
    ];
  }

  # A macOS host starts the cluster at login inside the Podman machine, as a
  # NixOS host's user unit does on rootless Podman. The first start pulls
  # images, so a bootstrap generation starts none.
  (lib.mkIf (config.my.kind == "darwin" && !config.my.bootstrap) {
    # A hand-run `minikube start` then picks the same cluster as the agent.
    # MINIKUBE_ROOTLESS is left out: minikube ignores it on macOS.
    home.sessionVariables = {
      MINIKUBE_PROFILE = "minikube";
      MINIKUBE_DRIVER = "podman";
      MINIKUBE_CONTAINER_RUNTIME = "containerd";
    };

    launchd.agents.minikube = {
      enable = true;
      config = {
        ProgramArguments = [
          (lib.getExe start)
          (lib.getExe podman)
          (lib.getExe pkgs.minikube)
          (toString startTimeout)
          (toString pollInterval)
          (toString node.memory)
          (toString node.cpus)
        ];
        # minikube runs podman by name.
        EnvironmentVariables.PATH = "${
          lib.makeBinPath [
            podman
            pkgs.minikube
          ]
        }:/usr/bin:/bin";
        RunAtLoad = true;
        KeepAlive.SuccessfulExit = false;
        ThrottleInterval = 60;
        # launchd would otherwise kill whatever minikube leaves running in the
        # job's process group when the job exits.
        AbandonProcessGroup = true;
        StandardOutPath = logFile;
        StandardErrorPath = logFile;
      };
    };
  })
]
