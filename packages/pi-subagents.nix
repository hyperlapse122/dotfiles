{ pkgs, pi }:

let
  release = import ./npm-release-package.nix {
    inherit pkgs;
    pname = "pi-subagents";
    release = ./pi-subagents-release.json;
    lockDirectory = ./pi-subagents;
  };
in
pkgs.buildNpmPackage (
  release.attrs
  // {
    nodejs = pkgs.nodejs_22;
    npmFlags = release.attrs.npmFlags ++ [ "--legacy-peer-deps" ];
    postPatch = release.attrs.postPatch + ''
      jq '.pi = {extensions: ["./dotfiles-entry.js"]}' package.json > package.json.tmp
      mv package.json.tmp package.json
      cp ${./pi-subagents/entry.js} dotfiles-entry.js
    '';
    # The published bundle has native ESM imports that do not use Pi's
    # extension aliases. Resolve those peers from the same pinned Pi build.
    postInstall = ''
      deps="$out/lib/node_modules/pi-subagents/node_modules"
      ln -s ${pi.nodeModules}/@earendil-works "$deps/@earendil-works"
      ln -s ${pi.nodeModules}/typebox "$deps/typebox"
    '';
    meta = {
      description = "Subagent delegation for Pi";
      homepage = "https://github.com/nicobailon/pi-subagents";
      license = pkgs.lib.licenses.mit;
    };
  }
)
