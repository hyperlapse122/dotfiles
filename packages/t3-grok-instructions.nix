{ pkgs }:
let
  grok = import ./grok-build.nix { inherit pkgs; };
in
pkgs.stdenvNoCC.mkDerivation {
  pname = "t3-grok-instructions";
  version = "1";
  dontUnpack = true;
  nativeBuildInputs = [ pkgs.makeWrapper ];
  installPhase = ''
    install -Dm755 ${../scripts/t3-grok-instructions.py} $out/libexec/t3-grok-instructions.py
    makeWrapper ${pkgs.python3}/bin/python3 $out/bin/t3-grok-instructions \
      --add-flags "$out/libexec/t3-grok-instructions.py" \
      --prefix PATH : ${pkgs.lib.makeBinPath [ grok ]}
  '';
  doInstallCheck = true;
  nativeInstallCheckInputs = [ pkgs.python3 ];
  installCheckPhase = ''
    runHook preInstallCheck
    python3 ${../tests/test_t3_grok_instructions.py} $out/libexec/t3-grok-instructions.py
    $out/bin/t3-grok-instructions --version
    python3 ${../tests/test_t3_grok_runtime.py} $out/bin/t3-grok-instructions
    runHook postInstallCheck
  '';
  meta.mainProgram = "t3-grok-instructions";
}
