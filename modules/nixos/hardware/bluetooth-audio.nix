{ ... }:
{
  # WirePlumber switches a Bluetooth headset from A2DP to the mono HFP/HSP
  # headset profile whenever any application opens an input stream, which
  # drops playback quality. Keep A2DP; the headset profile stays available for
  # manual selection.
  services.pipewire.wireplumber.extraConfig."51-disable-bt-autoswitch" = {
    "wireplumber.settings" = {
      "bluetooth.autoswitch-to-headset-profile" = false;
    };
  };
}
