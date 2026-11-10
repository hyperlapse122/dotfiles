/*
  The Antigravity ACP runtime's two binaries in one bin/ directory on PATH,
  for Compound Engineering's Antigravity route: it finds the runtime with
  `command -v agy_acp_server.par` and takes localharness_external from the
  same directory.

  agy_acp_server.par is a wrapper that execs the runtime by its absolute store
  path. The .par loads its embedded archive through argv[0], and acpx spawns
  it by bare name, so a symlink would hand it `agy_acp_server.par`; nothing
  may pass `-a` either. The Linux .par embeds an OpenSSL whose default CA path
  does not exist on NixOS, and a session without SSL_CERT_FILE hangs after
  session/prompt, so on Linux the wrapper supplies a bundle when the caller set
  none: the first system bundle that exists, so local CAs still apply, then
  the nixpkgs one.

  Compound Engineering gives each run a private GEMINI_HOME, `gemini-home`
  under a mktemp -d directory, and copies the sign-in into it itself. The
  runtime reads skills only from GEMINI_HOME, so when GEMINI_HOME is such a
  run home the wrapper links into it each skill in `skills` that exists under
  ~/.gemini/antigravity-cli/skills/. Home Manager passes the names
  home/h82/agents/skills.nix links there. The ACP runtime loads no global
  rule files from any location, so the shared rules are not linked. Any
  other GEMINI_HOME, such as T3 Code's instance homes, is left alone.

  The runtime defaults to packages/antigravity-acp-release.json, which
  scripts/antigravity-acp-release keeps at Google's newest complete release.
  tests/antigravity-acp-path.nix passes a stub runtime instead: the real one
  is about 1 GB unpacked and needs network and a Google sign-in to run, so only
  a stub can report the argv[0], pid, and environment the wrapper execs it with.
*/
{
  pkgs,
  skills ? [ ],
  runtime ? import ./antigravity-acp.nix {
    inherit pkgs;
    pins = (builtins.fromJSON (builtins.readFile ./antigravity-acp-release.json)).platforms;
  },
}:

let
  inherit (pkgs) lib;
  inherit (runtime.passthru.pin) executable harness;
  dir = "${runtime}/libexec/antigravity-acp";
  coreutils = "${pkgs.coreutils}/bin";

  # The system bundles first, so local CAs still apply, then the nixpkgs one.
  caBundles = [
    "/etc/ssl/certs/ca-certificates.crt"
    "/etc/pki/tls/certs/ca-bundle.crt"
    "/etc/ssl/cert.pem"
    "/etc/ssl/ca-bundle.pem"
    "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
  ];

  # The mktemp -d templates of Compound Engineering's cross-model scripts
  # whose directory holds an Antigravity run home. tests/antigravity-acp-path.nix
  # compares them with the pinned plugin.
  runHomePrefixes = [
    "ce-work-adapter-"
    "ce-work-model-check-"
    "xmodel-cr-scratch-"
    "xmodel-doc-peer-"
    "xmodel-doc-scratch-"
    "xmodel-pov-peer-"
  ];

  wrapper = pkgs.writeShellScript executable.name ''
    ${lib.optionalString pkgs.stdenv.hostPlatform.isLinux ''
      if [ -z "''${SSL_CERT_FILE:-}" ]; then
        for bundle in ${lib.escapeShellArgs caBundles}; do
          if [ -f "$bundle" ]; then
            export SSL_CERT_FILE="$bundle"
            break
          fi
        done
      fi
    ''}
    strip_slashes() {
      local value=''${!1}
      while [ "''${value%/}" != "$value" ]; do
        value=''${value%/}
      done
      printf -v "$1" '%s' "$value"
    }

    private_dir() {
      [ -d "$1" ] && [ ! -L "$1" ] && [ -O "$1" ]
    }

    # Creates a private directory unless something is already there, and
    # succeeds only when the path ends up a private directory.
    private_subdir() {
      [ -e "$1" ] || [ -L "$1" ] || ${coreutils}/mkdir -m 700 "$1" || return 1
      private_dir "$1"
    }

    link_run_home() {
      local gemini_home=''${GEMINI_HOME:-} parent
      strip_slashes gemini_home
      case $gemini_home in
        */gemini-home) ;;
        *) return 0 ;;
      esac
      parent=''${gemini_home%/gemini-home}
      strip_slashes parent
      case ''${parent##*/} in
        ${lib.concatMapStringsSep " | " (prefix: "${prefix}*") runHomePrefixes}) ;;
        *) return 0 ;;
      esac
      private_dir "$parent" && private_dir "$gemini_home" || return 0
      [ "$(${coreutils}/stat -c %a "$parent" 2>/dev/null)" = 700 ] || return 0
      [ -n "''${HOME:-}" ] || return 0

      (
        umask 077
        skills_dir=$gemini_home/antigravity-cli/skills
        src_dir=$HOME/.gemini/antigravity-cli/skills
        private_subdir "$gemini_home/antigravity-cli" || exit 0
        private_subdir "$skills_dir" || exit 0
        for skill in ${lib.escapeShellArgs skills}; do
          src=$src_dir/$skill
          dest=$skills_dir/$skill
          if [ -e "$src" ] && [ ! -e "$dest" ] && [ ! -L "$dest" ]; then
            ${coreutils}/ln -s "$src" "$dest" || true
          fi
        done
      ) 2>/dev/null || true
    }

    link_run_home
    exec ${dir}/${executable.name} "$@"
  '';
in
pkgs.runCommand "antigravity-acp-path-${runtime.version}"
  {
    pname = "antigravity-acp-path";
    inherit (runtime) version;
    meta = {
      description = "Antigravity ACP runtime on PATH for Compound Engineering";
      inherit (runtime.meta) homepage license platforms;
    };
  }
  ''
    mkdir -p $out/bin
    install -m 555 ${wrapper} $out/bin/${executable.name}
    ln -s ${dir}/${harness.name} $out/bin/${harness.name}
  ''
