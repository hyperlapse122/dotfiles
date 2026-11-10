/*
  VM check set interface:

    import ./tests/vm-checks.nix { inherit pkgs inputs linuxFixtures; }

  The VM tests, each needing /dev/kvm and the `nixos-test` and `kvm`
  system features. flake.nix exposes them as
  `legacyPackages.x86_64-linux.vmChecks`, outside `checks`, so `nix flake
  check` stays fast and runs without KVM. Build one with
  `nix build .#vmChecks.<name>`, or every one with `nix build .#vmChecks.all`.
  CI builds each in the `vm-checks` matrix of .github/workflows/check.yml.

  A new VM test belongs here, not in `checks`; the `vm-checks-guard` check
  fails when one is registered there.
*/
{
  pkgs,
  inputs,
  linuxFixtures,
}:
{
  boot-layout = import ./boot-layout.nix { inherit pkgs inputs; };
  auth-provisioning = import ./auth-provisioning.nix { inherit pkgs inputs; };
  omp-activation = import ./omp-activation.nix { inherit pkgs inputs; };
  desktop-ssh-integration = import ./desktop-ssh-integration.nix { inherit pkgs; };
  desktop-ssh-session = import ./desktop-ssh-session.nix { inherit pkgs inputs; };
  wifi-provisioning = import ./wifi-provisioning.nix { inherit pkgs inputs; };
  tailscale-provisioning = import ./tailscale-provisioning.nix { inherit pkgs inputs; };
  podman-registry-auth = import ./podman-registry-auth.nix { inherit pkgs inputs; };
  podman-prune = import ./podman-prune.nix { inherit pkgs; };
  gpg-agent-relay = import ./gpg-agent-relay.nix { inherit pkgs inputs; };
  non-nixos-vm = import ./non-nixos-vm.nix {
    inherit pkgs inputs;
    fixtures = linuxFixtures;
  };
}
