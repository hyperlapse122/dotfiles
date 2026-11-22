{ config, pkgs, ... }:
let
  # The SDDM greeter runs as the sddm user and cannot enter the mode-700 home
  # directory, so ~/.face.icon never reaches it. SDDM checks
  # <FacesDir>/<user>.face.icon first, and FacesDir is the system profile's
  # share/sddm/faces on NixOS.
  sddmFace = pkgs.linkFarm "user-sddm-face" {
    "share/sddm/faces/${config.my.user.name}.face.icon" = ../../../home/h82/assets/face.png;
  };
in
{
  environment.systemPackages = [ sddmFace ];
}
