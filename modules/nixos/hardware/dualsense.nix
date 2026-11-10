{ ... }:
{
  # libinput reads LIBINPUT_IGNORE_DEVICE from the udev database when a device
  # appears, so the rule works from 99-local.rules, where `extraRules` lands.
  # It hides only the touchpad's evdev node from the desktop pointer; the
  # gamepad and motion-sensor nodes, and the hidraw node Steam reads, keep
  # working.
  #
  # The kernel names the touchpad after the controller's HID name, which differs
  # by transport, so the rule matches each name exactly.
  services.udev.extraRules = ''
    # DualSense touchpad over USB
    ACTION=="add|change", ATTRS{name}=="Sony Interactive Entertainment DualSense Wireless Controller Touchpad", ENV{LIBINPUT_IGNORE_DEVICE}="1"

    # DualSense touchpad over Bluetooth
    ACTION=="add|change", ATTRS{name}=="DualSense Wireless Controller Touchpad", ENV{LIBINPUT_IGNORE_DEVICE}="1"
  '';
}
