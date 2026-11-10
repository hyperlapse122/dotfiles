/*
  Check interface:

    import ./tests/cargo-settings.nix { inherit pkgs self fixtures; }

  Asserts that `sccache` and the Cargo `build.rustc-wrapper` declared set reach
  user `h82` (or the fixture host's `my.user.name`) on every Home Manager user
  `tests/lib/configurations.nix` yields (NixOS and non-NixOS Linux hosts,
  production and bootstrap outputs alike).

  Verifies, per user environment:
  - `home.path` carries an executable `bin/sccache` whose `--version` runs
    cleanly without starting a background server.
  - `home.activation.cargoSettings` exists and runs after `installPackages`, so
    a refusal cannot strand `linkGeneration` and `installPackages` behind it.
  - executing the activation snippet through `tests/lib/agent-activation.nix`
    invokes the packaged `agent-settings` merger with `--format toml` targeting
    `~/.cargo/config.toml` and `--declared` assigning only
    `build.rustc-wrapper = "${home.profileDirectory}/bin/sccache"`, honours
    `DRY_RUN`, preserves user comments, sibling `[build]` keys, and unowned
    tables, is byte-idempotent on a second run, creates an absent
    `~/.cargo/config.toml` with mode `0600`, and propagates merger failures.
  - no `home.file` entry targets `.cargo/config.toml`, which Cargo and the user
    own as a writable file.
  - neither `hm-session-vars.sh` nor `.config/environment.d/10-home-manager.conf`
    declares `RUSTC_WRAPPER`, `CARGO_BUILD_RUSTC_WRAPPER`, `CARGO_INCREMENTAL`,
    `SCCACHE_DIR`, `SCCACHE_CACHE_SIZE`, `CC`, `CXX`,
    `CMAKE_C_COMPILER_LAUNCHER`, or `CMAKE_CXX_COMPILER_LAUNCHER`.

  Every lookup carries an `or` fallback and conditional blocks sit behind
  `lib.optionalString`, so a removed declaration fails inside the builder rather
  than during evaluation.
*/
{
  pkgs,
  self,
  fixtures ? import ./lib/linux-fixtures.nix { inherit (self) inputs; },
}:
let
  inherit (pkgs) lib;

  configurations = import ./lib/configurations.nix { inherit pkgs self fixtures; };

  esc = value: lib.escapeShellArg (toString value);

  executeActivation = import ./lib/agent-activation.nix { inherit pkgs; };

  settingsFile = ".cargo/config.toml";

  forbiddenVariablesPattern = "^(export )?(RUSTC_WRAPPER|CARGO_BUILD_RUSTC_WRAPPER|CARGO_INCREMENTAL|SCCACHE_DIR|SCCACHE_CACHE_SIZE|CC|CXX|CMAKE_C_COMPILER_LAUNCHER|CMAKE_CXX_COMPILER_LAUNCHER)=";

  seed = ''
    # user comment survives
    [build]
    # sibling key survives
    jobs = 4
    rustc-wrapper = "old-wrapper"

    [alias]
    b = "build"

    [net]
    git-fetch-with-cli = true
  '';

  assertHost =
    entry:
    let
      hostName = entry.name;
      userConfig = entry.user;
      hasHome = userConfig ? home;
      homePath = if hasHome then (userConfig.home.path or "") else "";
      homeDirectory = if hasHome then (userConfig.home.homeDirectory or "") else "";
      profileDirectory = if hasHome then (userConfig.home.profileDirectory or "") else "";
      wrapperPath = "${profileDirectory}/bin/sccache";

      declared = {
        setPaths = [
          {
            path = [
              "build"
              "rustc-wrapper"
            ];
            value = wrapperPath;
          }
        ];
      };

      applied = {
        build = {
          jobs = 4;
          rustc-wrapper = wrapperPath;
        };
        alias.b = "build";
        net.git-fetch-with-cli = true;
      };

      activation = if hasHome then (userConfig.home.activation.cargoSettings or null) else null;
      script = if activation == null then "" else (activation.data or "");
      runsAfterPackages = lib.elem "installPackages" (
        if activation == null then [ ] else (activation.after or [ ])
      );
      targeted = lib.any (file: (file.enable or true) && (file.target or "") == settingsFile) (
        lib.attrValues (if hasHome then (userConfig.home.file or { }) else { })
      );

      environmentFile =
        if hasHome && (userConfig ? home-files) then
          "${userConfig.home-files}/.config/environment.d/10-home-manager.conf"
        else
          "";
      shellFile =
        if hasHome && (userConfig.home ? sessionVariablesPackage) then
          "${userConfig.home.sessionVariablesPackage}/etc/profile.d/hm-session-vars.sh"
        else
          "";

      activationAbsent = lib.optionalString (activation == null) ''
        echo 'missing home.activation.cargoSettings on ${hostName}' >&2
        failed=1
      '';

      activationPresent = lib.optionalString (activation != null) ''
        if [ ${esc (lib.boolToString runsAfterPackages)} != "true" ]; then
          echo 'home.activation.cargoSettings must run after installPackages on ${hostName}' >&2
          failed=1
        fi
        ${executeActivation {
          inherit script;
          home = homeDirectory;
          contract = {
            file = settingsFile;
            format = "toml";
            inherit declared;
            inherit seed;
            expected = applied;
          };
        }}
      '';
    in
    ''
      if [ -z ${esc homePath} ] || [ ! -x "${homePath}/bin/sccache" ]; then
        echo 'sccache is not in home.path on ${hostName}' >&2
        failed=1
      elif ! "${homePath}/bin/sccache" --version >/dev/null 2>&1; then
        echo 'sccache --version failed on ${hostName}' >&2
        failed=1
      fi

      ${activationAbsent}${activationPresent}

      if [ ${esc (lib.boolToString targeted)} != "false" ]; then
        echo 'Home Manager must not target ~/${settingsFile} on ${hostName}; Cargo owns it' >&2
        failed=1
      fi

      if [ -n ${esc environmentFile} ] && [ -f ${esc environmentFile} ] \
        && grep -Eq ${esc forbiddenVariablesPattern} ${esc environmentFile}; then
        echo 'environment.d/10-home-manager.conf defines a forbidden Rust/sccache/C++ wrapper override on ${hostName}' >&2
        failed=1
      fi

      if [ -n ${esc shellFile} ] && [ -f ${esc shellFile} ] \
        && grep -Eq ${esc forbiddenVariablesPattern} ${esc shellFile}; then
        echo 'hm-session-vars.sh defines a forbidden Rust/sccache/C++ wrapper override on ${hostName}' >&2
        failed=1
      fi
    '';
in
pkgs.runCommand "cargo-settings-tests" { } ''
  ${configurations.userGuard}
  failed=0

  ${lib.concatMapStringsSep "\n" assertHost configurations.userEntries}

  if [ "$failed" != "0" ]; then
    exit 1
  fi

  touch $out
''
