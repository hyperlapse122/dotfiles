# The x86_64 fixture: a non-default account, as on a work machine. It sets
# the NixOS-only WiFiman trait, so a check sees that the trait installs
# nothing on a non-NixOS host.
{
  my.user.name = "tester";
  my.user.home = "/home/tester";
  my.user.gpgKey = "0123456789ABCDEF0123456789ABCDEF01234567";
  my.wifiman.enable = true;
}
