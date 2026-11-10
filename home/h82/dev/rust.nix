{
  config,
  lib,
  pkgs,
  ...
}:
let
  merger = "${
    (import ../../../packages/agent-tools.nix { inherit pkgs; }).agentSettings
  }/bin/agent-settings";

  # Cargo and the user both write under ~/.cargo/ and may maintain registries,
  # aliases, or build flags in ~/.cargo/config.toml, so activation assigns only
  # the default wrapper key and leaves everything else intact. Pointing at the
  # active Home Manager profile symlink gives GUI tools and non-login services
  # an absolute path without embedding a transient store hash that rollbacks or
  # garbage collection could invalidate.
  # Retiring sccache requires a removePaths entry for build.rustc-wrapper rather
  # than dropping this block, or ~/.cargo/config.toml keeps pointing at the
  # removed binary.
  declared = pkgs.writeText "cargo-declared-settings.json" (
    builtins.toJSON {
      setPaths = [
        {
          path = [
            "build"
            "rustc-wrapper"
          ];
          value = "${config.home.profileDirectory}/bin/sccache";
        }
      ];
    }
  );
in
{
  # rustup honours each project's rust-toolchain.toml; the toolchains it
  # downloads are dynamically linked and run through nix-ld. The first
  # toolchain is a one-time `rustup default stable`.
  home.packages = [
    pkgs.rustup
    pkgs.sccache
  ];

  # `cargo install` puts binaries here; the Nix rustup does not add it itself.
  home.sessionPath = [ "${config.home.homeDirectory}/.cargo/bin" ];

  # Ordered after installPackages as on codexSettings in agents/codex.nix: a
  # refusal must fail the rebuild loudly without stranding linkGeneration or
  # installPackages behind it.
  home.activation.cargoSettings = lib.hm.dag.entryAfter [ "installPackages" ] ''
    if [[ ! -v DRY_RUN ]]; then
      ${merger} \
        --format toml \
        --label Cargo \
        --settings ${config.home.homeDirectory}/.cargo/config.toml \
        --declared ${declared}
    fi
  '';
}
