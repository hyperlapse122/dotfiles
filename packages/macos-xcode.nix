{ pkgs }:
let
  xcodes = pkgs.xcodes.overrideAttrs (previous: {
    postPatch = (previous.postPatch or "") + ''
      # SwiftPM links vendored sources from the read-only store.
      unlink Packages
      mkdir Packages
      ln -s "$swiftpmDeps"/Packages/* Packages/
      unlink Packages/XcodesKit
      cp -R "$swiftpmDeps/Packages/XcodesKit" Packages/XcodesKit
      chmod -R u+w Packages/XcodesKit
      patch -d Packages/XcodesKit -p1 < ${./xcodes-aria2-cookies.patch}
      cp ${../tests/xcodes-aria2.swift} Tests/XcodesKitTests/Aria2CookieTests.swift
    '';
    doCheck = true;
    checkPhase = ''
      (
        swiftpmFlagsArray+=(--filter aria2UsesScopedCookieFile)
        SSL_CERT_FILE=/fixture-ca.pem swiftpmCheckPhase
      )
    '';
  });
in
pkgs.writeShellApplication {
  name = "macos-xcode";
  runtimeInputs = [
    pkgs.python3
    pkgs.sops
    xcodes
  ];
  text = ''exec python3 ${../scripts/macos-xcode.py} "$@"'';
}
