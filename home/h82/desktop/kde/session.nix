{ pkgs, lib, ... }:
let
  kwrite = "${pkgs.kdePackages.kconfig}/bin/kwriteconfig6";
in
{
  home.activation.kdeSession = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    if [ -x "${kwrite}" ]; then
      # ksmserverrc: always start with an empty session (never restore previous session on boot)
      ${kwrite} --file ksmserverrc --group General --key loginMode emptySession

      # powerdevilrc: idle screen dimming configuration
      # AC profile: do not dim screen when idle
      ${kwrite} --file powerdevilrc --group AC --group Display --key DimDisplayWhenIdle --type bool false
      ${kwrite} --file powerdevilrc --group AC --group Display --key DimDisplayIdleTimeoutSec -- -1

      # Battery profile: dim screen after 120 seconds
      ${kwrite} --file powerdevilrc --group Battery --group Display --key DimDisplayWhenIdle --type bool true
      ${kwrite} --file powerdevilrc --group Battery --group Display --key DimDisplayIdleTimeoutSec -- 120

      # Low battery profile: dim screen after 60 seconds
      ${kwrite} --file powerdevilrc --group LowBattery --group Display --key DimDisplayWhenIdle --type bool true
      ${kwrite} --file powerdevilrc --group LowBattery --group Display --key DimDisplayIdleTimeoutSec -- 60

    fi
  '';
}
