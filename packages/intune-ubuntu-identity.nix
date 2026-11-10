/*
  Package interface:

    identity = pkgs.callPackage ./packages/intune-ubuntu-identity.nix { };
    identity.wrap package [ "name" ... ]   package with those bin/ entries wrapped

  Microsoft supports the Intune app on Ubuntu and RHEL only, and every Intune
  and identity broker executable that reads /etc/os-release refuses or
  misreports a NixOS host. `wrap` starts each named executable in its own
  mount namespace, where the Ubuntu file is bound over /etc/os-release, so
  only those processes see Ubuntu and the system keeps its NixOS identity.

  The real executable moves to libexec/intune-ubuntu-identity and the wrapper
  takes its place under bin/, so the unit, D-Bus service, and desktop files
  that nixpkgs already points at bin/ start the wrapper unchanged.

  The namespace keeps the host's whole mount tree: intune-agent judges disk
  encryption from its own /proc/mounts, so a sparse root would misreport it.
  bubblewrap refuses to mount on a symlink, and /etc/os-release is one on
  NixOS, so the bind lands on the file the link resolves to.
*/
{
  lib,
  bubblewrap,
  coreutils,
  runtimeShell,
  writeText,
}:
let
  osRelease = writeText "ubuntu-os-release" ''
    PRETTY_NAME="Ubuntu 24.04.3 LTS"
    NAME="Ubuntu"
    VERSION_ID="24.04"
    VERSION="24.04.3 LTS (Noble Numbat)"
    VERSION_CODENAME=noble
    ID=ubuntu
    ID_LIKE=debian
    HOME_URL="https://www.ubuntu.com/"
    SUPPORT_URL="https://help.ubuntu.com/"
    BUG_REPORT_URL="https://bugs.launchpad.net/ubuntu/"
    PRIVACY_POLICY_URL="https://www.ubuntu.com/legal/terms-and-policies/privacy-policy"
    UBUNTU_CODENAME=noble
    LOGO=ubuntu-logo
  '';

  libexecDir = "$out/libexec/intune-ubuntu-identity";

  wrapOne = name: ''
    if [ ! -x "$out/bin/${name}" ]; then
      echo "intune-ubuntu-identity: $out/bin/${name} is not an executable to wrap" >&2
      exit 1
    fi
    # A second wrap would move the wrapper over the real executable and leave
    # a script that starts itself without end.
    if [ -e "${libexecDir}/${name}" ]; then
      echo "intune-ubuntu-identity: $out/bin/${name} is already wrapped" >&2
      exit 1
    fi
    mv "$out/bin/${name}" "${libexecDir}/${name}"
    cat > "$out/bin/${name}" <<EOF
    #!${runtimeShell}
    exec ${bubblewrap}/bin/bwrap --dev-bind / / --ro-bind ${osRelease} "\$(${coreutils}/bin/realpath /etc/os-release)" -- "${libexecDir}/${name}" "\$@"
    EOF
    chmod +x "$out/bin/${name}"
  '';
in
{
  wrap =
    package: names:
    package.overrideAttrs (old: {
      postInstall = (old.postInstall or "") + ''
        mkdir -p "${libexecDir}"
        ${lib.concatMapStrings wrapOne names}
      '';
    });
}
