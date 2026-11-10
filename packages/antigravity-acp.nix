/*
  An Antigravity ACP runtime on this system, unpacked the way T3 Code's own
  installer unpacks it: both binaries in one libexec/antigravity-acp/
  directory, byte for byte as Google ships them.

  `pins` is required and has no default, so a caller that forgets it fails
  evaluation instead of building another runtime. It maps each system to its
  release record. packages/antigravity-acp-path.nix passes the platforms of
  packages/antigravity-acp-release.json, which scripts/antigravity-acp-release
  keeps at Google's newest complete release; T3 Code's instance passes the
  antigravity section of packages/t3code-release.json, the release the pinned
  T3 Code embeds. The archive hash is the sha256 T3 Code verifies.
*/
{ pkgs, pins }:

let
  system = pkgs.stdenv.hostPlatform.system;
  pin = pins.${system} or (throw "the Antigravity ACP pins name no runtime for ${system}");
in
pkgs.stdenvNoCC.mkDerivation {
  pname = "antigravity-acp";
  inherit (pin) version;

  src = pkgs.fetchurl {
    inherit (pin) url hash;
  };

  nativeBuildInputs = [ pkgs.unzip ];
  sourceRoot = ".";

  # T3 Code checks each binary's exact byte size, and the .par executable
  # carries an appended archive, so fixup's stripping and patching would
  # break both. NixOS runs the unpatched binaries through nix-ld.
  dontFixup = true;

  installPhase = ''
    runHook preInstall

    # Moved rather than copied: the binaries are about 1 GB unpacked on Linux.
    mkdir -p $out/libexec/antigravity-acp
    mv ${pin.executable.name} ${pin.harness.name} $out/libexec/antigravity-acp/
    chmod 555 $out/libexec/antigravity-acp/*

    runHook postInstall
  '';

  passthru = { inherit pin; };

  meta = {
    description = "Google Antigravity ACP server";
    homepage = "https://antigravity.google";
    license = pkgs.lib.licenses.unfree;
    platforms = builtins.attrNames pins;
    sourceProvenance = [ pkgs.lib.sourceTypes.binaryNativeCode ];
  };
}
