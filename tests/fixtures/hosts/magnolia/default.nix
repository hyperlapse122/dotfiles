# The macOS fixture: a non-default account under /Users, as on a work Mac, and
# both T3 Code traits, so the pinned desktop app and CLI are both built, and
# the TLS inspection CA trait with a fake CA, the network recovery trait, and
# the wired network trait with a fake declaration.
# Its one Dock host app lets a check see where host apps land in the order.
{
  my.user.name = "tester";
  my.user.home = "/Users/tester";
  my.t3.cli.enable = true;
  my.t3.desktop.enable = true;
  my.tlsInspectionCa.enable = true;
  my.networkRecovery.enable = true;
  my.wiredNetwork.enable = true;
  my.dock.hostApps = [ "/Applications/Fixture Work.app" ];
}
