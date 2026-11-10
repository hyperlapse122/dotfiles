{ pkgs, lib, ... }:
let
  kwrite = "${pkgs.kdePackages.kconfig}/bin/kwriteconfig6";
in
{
  home.activation.kdeKwin = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    if [ -x "${kwrite}" ]; then
      # kwinrc: disable electric border actions (screen edge/corner triggers)
      for edge in Top TopRight Right BottomRight Bottom BottomLeft Left TopLeft; do
        ${kwrite} --file kwinrc --group ElectricBorders --key "$edge" None
      done

      # kwinrc: disable multi-monitor edge barriers
      ${kwrite} --file kwinrc --group EdgeBarrier --key CornerBarrier --type bool false
      ${kwrite} --file kwinrc --group EdgeBarrier --key EdgeBarrier -- 0

      # kwinrc: Wayland virtual keyboard launcher
      ${kwrite} --file kwinrc --group Wayland --key InputMethod --type path /run/current-system/sw/share/applications/fcitx5-wayland-launcher.desktop

      # kwinrulesrc: keep authentication dialogs always on top
      ${kwrite} --file kwinrulesrc --group General --key rules "1password-auth-above,polkit-auth-above"
      ${kwrite} --file kwinrulesrc --group General --key count -- 2

      # 1Password auth dialog always on top (dialogs only, types=32)
      ${kwrite} --file kwinrulesrc --group 1password-auth-above --key Description "1Password Auth Dialog Always on Top"
      ${kwrite} --file kwinrulesrc --group 1password-auth-above --key wmclass 1password
      ${kwrite} --file kwinrulesrc --group 1password-auth-above --key wmclassmatch -- 1
      ${kwrite} --file kwinrulesrc --group 1password-auth-above --key title 1Password
      ${kwrite} --file kwinrulesrc --group 1password-auth-above --key titlematch -- 1
      ${kwrite} --file kwinrulesrc --group 1password-auth-above --key types -- 32
      ${kwrite} --file kwinrulesrc --group 1password-auth-above --key typesrule -- 2
      ${kwrite} --file kwinrulesrc --group 1password-auth-above --key above --type bool true
      ${kwrite} --file kwinrulesrc --group 1password-auth-above --key aboverule -- 3

      # Polkit auth dialog always on top
      ${kwrite} --file kwinrulesrc --group polkit-auth-above --key Description "Polkit Auth Dialog Always on Top"
      ${kwrite} --file kwinrulesrc --group polkit-auth-above --key wmclass polkit-kde-authentication-agent-1
      ${kwrite} --file kwinrulesrc --group polkit-auth-above --key wmclassmatch -- 2
      ${kwrite} --file kwinrulesrc --group polkit-auth-above --key types -- 32
      ${kwrite} --file kwinrulesrc --group polkit-auth-above --key typesrule -- 2
      ${kwrite} --file kwinrulesrc --group polkit-auth-above --key above --type bool true
      ${kwrite} --file kwinrulesrc --group polkit-auth-above --key aboverule -- 3
    fi
  '';
}
