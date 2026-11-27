# The macOS fixture: a non-default account under /Users, as on a work Mac, the
# TLS inspection CA trait with a fake CA, the network recovery trait, and the
# wired network trait with a fake declaration.
# Its one Dock host app lets a check see where host apps land in the order.
{
  my.user.name = "tester";
  my.user.home = "/Users/tester";
  my.tlsInspectionCa.enable = true;
  my.networkRecovery.enable = true;
  my.wiredNetwork.enable = true;
  my.dock.hostApps = [ "/Applications/Fixture Work.app" ];
}
