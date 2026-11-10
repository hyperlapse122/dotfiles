{ config, lib, ... }:
{
  # resolved keeps an NXDOMAIN for the zone's SOA minimum TTL (1800 s on
  # Cloudflare), so a name looked up before its record existed stays
  # unresolvable for that long. Positive answers are still cached. Keyed on
  # resolved itself so any module that enables it gets the same policy.
  config = lib.mkIf config.services.resolved.enable {
    services.resolved.settings.Resolve = {
      Cache = "no-negative";
      # Avahi answers and resolves mDNS when it runs; a second responder in
      # resolved on port 5353 competes with it for the same names.
      MulticastDNS = lib.mkIf config.services.avahi.enable "false";
    };
  };
}
