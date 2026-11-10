{
  config,
  lib,
  ...
}:
let
  cfg = config.my.podman;
in
{
  options.my.podman = {
    enable = lib.mkEnableOption "rootless Podman container runtime with Docker CLI compatibility";
  };

  config = lib.mkIf cfg.enable {
    virtualisation.podman = {
      enable = true;
      dockerCompat = true;
    };

    # Disable the rootful systemd socket so only the rootless user socket is active.
    # virtualisation.podman.enable adds "sockets.target" to systemd.sockets.podman.wantedBy,
    # which starts the rootful daemon socket. We explicitly empty it.
    systemd.sockets.podman.wantedBy = lib.mkForce [ ];

    # A rootless container cannot mknod, so `--device /dev/kvm` bind-mounts
    # the host's node, which root inside the container cannot chmod, and
    # container users such as nixbld are not in the host's kvm group. The host
    # mode alone decides whether they get KVM, so pin it rather than inherit
    # systemd's dev-kvm-mode build default. extraRules lands in
    # 99-local.rules, so this MODE is applied last, and static_node makes udevd
    # apply it to the node kmod-static-nodes creates before KVM loads. The
    # tmpfiles entry covers that node before udevd starts: tmpfiles applies the
    # earliest-named file's entry for a path, and the rules option lands in
    # 00-nixos.conf, ahead of systemd's static-nodes-permissions.conf. MODE
    # precedes GROUP so the line differs from systemd's own and
    # tests/udev-device-access.nix can tell them apart.
    services.udev.extraRules = ''
      KERNEL=="kvm", MODE="0666", GROUP="kvm", OPTIONS+="static_node=kvm"
    '';
    systemd.tmpfiles.rules = [ "z /dev/kvm 0666 - kvm -" ];

    # Rootless Podman needs /etc/subuid and /etc/subgid entries. nixpkgs only
    # sets this with mkDefault for normal users that declare no explicit ranges.
    users.users.${config.my.user.name}.autoSubUidGidRange = true;

    # virtualisation.podman.autoPrune runs as root against rootful storage,
    # which holds nothing here, so prune each user's rootless storage from
    # their own user manager instead. The wrapped package keeps /run/wrappers
    # on PATH for newuidmap, which the unit's own PATH would otherwise drop.
    # System accounts, such as the display manager's, have no subordinate ID
    # ranges, so the prune runs only in the configured account's manager.
    # minikube does not recreate a Podman node container that a prune
    # removed, so a stopped cluster would only come back through
    # `minikube delete`; the label filter keeps its container and network.
    systemd.user.services.podman-prune = {
      description = "Prune unused rootless Podman containers, networks, and dangling images";
      unitConfig.ConditionUser = config.my.user.name;
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${config.virtualisation.podman.package}/bin/podman system prune --force --filter label!=created_by.minikube.sigs.k8s.io";
      };
    };

    systemd.user.timers.podman-prune = {
      description = "Weekly rootless Podman prune";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "weekly";
        Persistent = true;
        RandomizedDelaySec = "1h";
      };
    };
  };
}
