{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.my.minikube;

  # minikube reads these instead of flags or `minikube config`, so the unit
  # and a hand-run `minikube start` choose the same rootless Podman cluster.
  # Without MINIKUBE_ROOTLESS the Podman driver runs `sudo -n podman`.
  # MINIKUBE_PROFILE pins the cluster over the profile `minikube profile`
  # persists, so a switch mid-session cannot redirect the unit's stop.
  minikubeEnvironment = {
    MINIKUBE_PROFILE = "minikube";
    MINIKUBE_DRIVER = "podman";
    MINIKUBE_CONTAINER_RUNTIME = "containerd";
    MINIKUBE_ROOTLESS = "true";
  };
in
{
  options.my.minikube = {
    enable = lib.mkEnableOption "a rootless minikube cluster on rootless Podman, started with the user's session";
  };

  config = lib.mkIf cfg.enable {
    environment.sessionVariables = minikubeEnvironment;

    # The rootless node needs the cpuset and io controllers, which systemd
    # does not delegate to user managers by default. NixOS does not restart
    # user@ on switch, so this applies after a reboot or a full logout.
    systemd.services."user@".serviceConfig.Delegate = "cpu cpuset io memory pids";

    # Type=exec is active once minikube runs, so a first start that pulls
    # images for minutes does not hold default.target, and with it login.
    # RemainAfterExit keeps the unit active after a successful start, so
    # ExecStop stops the node at session end and its state stays on disk.
    # System accounts, such as the display manager's, have no subordinate ID
    # ranges, so the cluster starts only in the configured account's manager.
    systemd.user.services.minikube = {
      description = "Rootless minikube cluster";
      wantedBy = [ "default.target" ];
      unitConfig.ConditionUser = config.my.user.name;
      # The wrapped Podman keeps /run/wrappers on PATH for newuidmap.
      path = [ config.virtualisation.podman.package ];
      environment = minikubeEnvironment;
      serviceConfig = {
        Type = "exec";
        RemainAfterExit = true;
        ExecStart = "${lib.getExe pkgs.minikube} start";
        ExecStop = "${lib.getExe pkgs.minikube} stop";
      };
    };
  };
}
