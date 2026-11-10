{ lib, pkgs, ... }:
{
  # The real kubectl takes priority over minikube's downloading shim.
  home.packages = [
    (lib.hiPrio pkgs.kubectl)
    pkgs.kubernetes-helm
    pkgs.minikube
  ];
}
