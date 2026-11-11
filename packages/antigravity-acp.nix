/*
  The Antigravity ACP runtime on this system, unpacked the way T3 Code's own
  installer unpacks it, then rebuilt with this repository's additions: both
  binaries in one libexec/antigravity-acp/ directory, the helper byte for byte
  as Google ships it.

  The only pin is the antigravity section of packages/t3code-release.json, the
  release the pinned T3 Code embeds. T3 Code sends its session system prompt
  only to a runtime that reports exactly that version, so the rebuilt runtime
  keeps it. The archive hash is the sha256 T3 Code verifies.

  scripts/antigravity-acp-repack rewrites the .par's embedded archive at its
  original length: packages/antigravity-acp-overlay/ adds the shared agent
  instructions to the client's system prompt and the plugin skills directory to
  the skill path. On macOS the build then signs the result ad hoc, because the
  rewrite invalidates Google's signature and library validation under Google's
  hardened-runtime flag would refuse the runtime's own Google-signed native
  modules once the launcher has no Team ID.

  Fixup stays off: stripping or patching would break the embedded archive.
  NixOS runs the unpatched binaries through nix-ld. Linux cannot start the
  runtime inside the build sandbox, so its install check reads the archive;
  the macOS check also starts the runtime and requires an `initialize` answer.
*/
{ pkgs }:

let
  inherit (pkgs) lib;
  system = pkgs.stdenv.hostPlatform.system;
  isDarwin = pkgs.stdenv.hostPlatform.isDarwin;
  pins = (builtins.fromJSON (builtins.readFile ./t3code-release.json)).antigravity;
  pin =
    pins.${system} or (throw "packages/t3code-release.json pins no Antigravity runtime for ${system}");

  repack = (import ./agent-tools.nix { inherit pkgs; }).antigravityAcpRepack;
  overlays = ./antigravity-acp-overlay;
  moduleDirectory = "google3/cloud/developer_experience/antigravity_extensions/acp_server";
  pageSize = if isDarwin then 16384 else 4096;
  extensions = [
    {
      module = "system_prompt";
      function = "extract_system_prompt";
    }
    {
      module = "paths";
      function = "global_skills_paths";
    }
  ];
  extendArgs = lib.concatMapStringsSep " " (
    e:
    lib.escapeShellArgs [
      "--extend"
      "${moduleDirectory}/${e.module}.py"
      e.function
      "${overlays}/${e.module}_overlay.py"
    ]
  ) extensions;

  # Reads the rebuilt runtime's archive back through the rebuild tool's own
  # reader and checks what the rebuild promises: every entry matches its
  # checksum, each overlay is in the archive byte for byte, each extended module
  # ends with the line that imports its overlay, and its cached bytecode is gone.
  archiveCheck = pkgs.writeText "antigravity-acp-archive-check.py" ''
    import importlib.machinery
    import importlib.util
    import mmap
    import sys
    import zlib

    tool, runtime, page_size, directory, *pairs = sys.argv[1:]
    loader = importlib.machinery.SourceFileLoader("repack", tool)
    repack = importlib.util.module_from_spec(importlib.util.spec_from_loader("repack", loader))
    loader.exec_module(repack)
    modules = [pair.split("=", 1) for pair in pairs]


    def problems(view):
        archive = repack.read_archive(view, int(page_size), [f"{directory}/{m}.py" for m, _ in modules])
        entries = {entry.name: bytes(entry.data) for entry in archive.entries}
        found = [f"{entry.name} fails its checksum" for entry in archive.entries
                 if zlib.crc32(entry.data) != entry.crc]
        package = directory.replace("/", ".")
        for module, overlay in modules:
            with open(overlay, "rb") as handle:
                expected = handle.read()
            if entries.get(f"{directory}/{module}_overlay.py") != expected:
                found.append(f"{module}_overlay.py is missing or differs from the repository's")
            line = f"from {package} import {module}_overlay\n".encode()
            if not entries.get(f"{directory}/{module}.py", b"").endswith(line):
                found.append(f"{module}.py does not import its overlay")
            found += [f"{name} is still cached" for name in entries
                      if name.startswith(f"{directory}/__pycache__/{module}.")]
        return found


    with open(runtime, "rb") as handle, mmap.mmap(handle.fileno(), 0, access=mmap.ACCESS_READ) as view:
        found = problems(view)
    if found:
        sys.exit("\n".join(found))
  '';

  archiveCheckArgs = ''${lib.escapeShellArg "${repack}/bin/antigravity-acp-repack"} "$par" ${
    lib.escapeShellArgs (
      [
        (toString pageSize)
        moduleDirectory
      ]
      ++ map (e: "${e.module}=${overlays}/${e.module}_overlay.py") extensions
    )
  }'';
in
pkgs.stdenvNoCC.mkDerivation {
  pname = "antigravity-acp";
  inherit (pin) version;

  src = pkgs.fetchurl {
    inherit (pin) url hash;
  };

  nativeBuildInputs = [
    pkgs.unzip
    repack
  ]
  ++ lib.optional isDarwin pkgs.rcodesign;
  sourceRoot = ".";

  dontFixup = true;

  installPhase = ''
    runHook preInstall

    antigravity-acp-repack --page-size ${toString pageSize} ${extendArgs} \
      ${pin.executable.name} ${pin.executable.name}
    ${lib.optionalString isDarwin ''
      # linker-signed keeps the shipped identifier and drops the hardened
      # runtime flag.
      rcodesign sign --code-signature-flags linker-signed \
        ${pin.executable.name} signed
      mv signed ${pin.executable.name}
    ''}
    # Moved rather than copied: the binaries are about 1 GB unpacked on Linux.
    mkdir -p $out/libexec/antigravity-acp
    mv ${pin.executable.name} ${pin.harness.name} $out/libexec/antigravity-acp/
    chmod 555 $out/libexec/antigravity-acp/*

    runHook postInstall
  '';

  doInstallCheck = true;
  nativeInstallCheckInputs = [
    pkgs.python3
  ]
  ++ lib.optional isDarwin pkgs.writableTmpDirAsHomeHook;
  installCheckPhase = ''
    runHook preInstallCheck

    par=$out/libexec/antigravity-acp/${pin.executable.name}
    python3 -I ${archiveCheck} ${archiveCheckArgs}
    ${
      if isDarwin then
        ''
          signature=$(rcodesign print-signature-info "$par")
          grep -qF 'identifier: agy_acp_server' <<<"$signature" \
            || { echo "the runtime lost its shipped code-signing identifier" >&2; exit 1; }
          if grep -qF 'RUNTIME' <<<"$signature"; then
            echo "the runtime still carries the hardened-runtime flag" >&2
            exit 1
          fi

          # The runtime finds its archive through argv[0], so it starts by
          # absolute path.
          mkdir -p "$HOME/gemini-home"
          printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1,"clientCapabilities":{}}}' \
            | GEMINI_HOME="$HOME/gemini-home" timeout 120 "$par" >initialize.out 2>initialize.err || true
          grep -q '"result"' initialize.out \
            || { echo "the runtime did not answer initialize" >&2; cat initialize.err >&2; exit 1; }
        ''
      else
        ''
          [ "$(stat -c %s "$par")" = ${toString pin.executable.bytes} ] \
            || { echo "the rebuilt runtime is not ${toString pin.executable.bytes} bytes" >&2; exit 1; }
        ''
    }

    runHook postInstallCheck
  '';

  passthru = { inherit pin; };

  meta = {
    description = "Google Antigravity ACP server";
    homepage = "https://antigravity.google";
    license = lib.licenses.unfree;
    platforms = builtins.attrNames pins;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
}
