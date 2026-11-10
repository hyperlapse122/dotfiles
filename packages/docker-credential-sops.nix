{
  pkgs,
  routingTable,
}:

let
  credentialMap = pkgs.writeText "docker-credential-map.json" (builtins.toJSON routingTable);
in
pkgs.stdenvNoCC.mkDerivation {
  pname = "docker-credential-sops";
  version = "1";
  dontUnpack = true;
  nativeBuildInputs = [ pkgs.python3 ];
  installPhase = ''
    install -Dm755 ${../scripts/docker-credential-sops} $out/bin/docker-credential-sops
    substituteInPlace $out/bin/docker-credential-sops \
      --replace-fail '@CREDENTIAL_MAP@' '${credentialMap}'
    patchShebangs $out/bin/docker-credential-sops
  '';
  # Read by tests/darwin-config.nix; passthru leaves the derivation unchanged.
  passthru = { inherit routingTable; };
  meta.mainProgram = "docker-credential-sops";
}
