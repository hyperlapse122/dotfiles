{ pkgs }:
pkgs.buildGoModule {
  pname = "text-template";
  version = "1";
  src = ./text-template;
  vendorHash = null;
  meta.mainProgram = "text-template";
}
