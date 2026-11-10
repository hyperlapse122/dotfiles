{ pkgs }:
let
  fallback =
    if pkgs.stdenv.hostPlatform.isDarwin then
      pkgs.lib.getExe pkgs.pinentry_mac
    else
      pkgs.lib.getExe pkgs.pinentry-qt;
in
pkgs.rustPlatform.buildRustPackage {
  pname = "dotfiles-pinentry";
  version = "0.1.0";
  src = pkgs.lib.cleanSourceWith {
    src = ../.;
    filter =
      path: type:
      let
        relative = pkgs.lib.removePrefix (toString ../. + "/") path;
      in
      relative == "Cargo.toml"
      || relative == "Cargo.lock"
      || relative == "crates"
      || pkgs.lib.hasPrefix "crates/" relative;
  };
  cargoLock.lockFile = ../Cargo.lock;
  doCheck = true;
  postInstall = ''
    echo '${builtins.toJSON { inherit fallback; }}' > $out/bin/dotfiles-pinentry.json
    ln -s dotfiles-pinentry $out/bin/pinentry
  '';
  doInstallCheck = true;
  nativeInstallCheckInputs = [ pkgs.python3 ];
  installCheckPhase = ''
        python3 - "$out/bin/dotfiles-pinentry.json" <<'PY'
    import json, os, sys
    fallback = json.load(open(sys.argv[1]))["fallback"]
    assert fallback.startswith("/nix/store/") and os.access(fallback, os.X_OK)
    assert fallback == ${builtins.toJSON fallback}
    PY
        $out/bin/dotfiles-pinentry --version
  '';
  meta.mainProgram = "dotfiles-pinentry";
}
