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

  The wrapper also sets what the identity broker's WebKitGTK sign-in window
  needs on this system and Ubuntu supplies by default; each export below says
  why. All wrappers carry the same environment so they stay one text.
*/
{
  lib,
  bubblewrap,
  coreutils,
  glib-networking,
  runCommandCC,
  runtimeShell,
  writeText,
}:
let
  # The broker reads WebKit's default User-Agent and sets it back without the
  # trailing Safari token. Microsoft's sign-in page takes that string for a
  # passkey-capable browser and sends an account that prefers a passkey to a
  # FIDO page this WebKitGTK cannot complete, with no way back to a password.
  # Passing NULL keeps the default string, which gets the password prompt.
  # Dropping the call instead makes the broker fail to start its browser.
  keepUserAgent = runCommandCC "intune-keep-webkit-user-agent" { } ''
    mkdir -p "$out/lib"
    $CC -shared -fPIC -O2 -o "$out/lib/keep-webkit-user-agent.so" -x c - <<'EOF'
    #define _GNU_SOURCE
    #include <dlfcn.h>
    void webkit_settings_set_user_agent(void *settings, const char *user_agent) {
      void (*real)(void *, const char *) = dlsym(RTLD_NEXT, "webkit_settings_set_user_agent");
      (void)user_agent;
      if (real) real(settings, 0);
    }
    EOF
    $NM -D --defined-only "$out/lib/keep-webkit-user-agent.so" | grep -q ' T webkit_settings_set_user_agent$'
  '';

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
    # The sign-in pages load in WebKitGTK, which finds its TLS backend only
    # through GIO modules and otherwise fails every HTTPS request.
    export GIO_EXTRA_MODULES="${glib-networking}/lib/gio/modules\''${GIO_EXTRA_MODULES:+:\$GIO_EXTRA_MODULES}"
    # WebKitGTK's DMA-BUF renderer and accelerated compositing leave the
    # sign-in window blank on the proprietary NVIDIA driver.
    export WEBKIT_DISABLE_DMABUF_RENDERER=1
    export WEBKIT_DISABLE_COMPOSITING_MODE=1
    # On the Wayland backend GDK reports a resolution of -1 to the broker's
    # window, WebKitGTK derives a negative device pixel ratio from it, and
    # the page lays out in a negative viewport that paints only its footer.
    export GDK_BACKEND=x11
    export LD_PRELOAD="${keepUserAgent}/lib/keep-webkit-user-agent.so\''${LD_PRELOAD:+:\$LD_PRELOAD}"
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
