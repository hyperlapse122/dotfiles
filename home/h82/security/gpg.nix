{
  config,
  lib,
  pkgs,
  ...
}:

let
  gpgTools = import ../../../packages/gpg-tools.nix { inherit pkgs; };
  relay = config.my.gpgAgentRelay;
in
{
  assertions = [
    {
      assertion = !relay.enable || relay.endpoint != null;
      message = "my.gpgAgentRelay.enable needs my.gpgAgentRelay.endpoint";
    }
  ];

  programs.gpg = {
    enable = true;
    publicKeys = [
      {
        source = ../../../keys/signing.asc;
        trust = "ultimate";
      }
      # The retired rsa2048 key, kept so commits and tags signed before the
      # rotation still verify.  No trust override: it signs nothing new.
      #
      # Deliberately the pre-revocation copy.  The key is revoked on
      # keys.openpgp.org, but merging that revocation in here makes
      # `git verify-commit` exit 1 on every pre-rotation commit: gpg still
      # reports a good signature and then adds a revocation warning, which git
      # treats as failure.  Do not "resync" this file with the keyserver.
      {
        source = ../../../keys/signing-legacy.asc;
      }
    ];
    settings = {
      cert-digest-algo = "SHA512";
      default-preference-list = "SHA512 SHA384 SHA256 AES256 AES192 AES ZLIB BZIP2 ZIP Uncompressed";
      display-charset = "utf-8";
      keyid-format = "0xlong";
      list-options = "show-uid-validity";
      no-comments = true;
      no-emit-version = true;
      no-symkey-cache = true;
      personal-cipher-preferences = "AES256 AES192 AES";
      personal-compress-preferences = "ZLIB BZIP2 ZIP Uncompressed";
      personal-digest-preferences = "SHA512 SHA384 SHA256";
      require-cross-certification = true;
      s2k-cipher-algo = "AES256";
      s2k-digest-algo = "SHA512";
      verify-options = "show-uid-validity";
      with-fingerprint = true;
      # A local agent started on demand would take the relay's socket.
      no-autostart = lib.mkIf relay.enable true;
    };
  };

  services.gpg-agent = lib.mkIf (!relay.enable) {
    enable = true;
    pinentry.package = gpgTools.pinentryCard;
    extraConfig = ''
      allow-loopback-pinentry
      default-cache-ttl 0
      max-cache-ttl 0
    '';
  };

  home.file.".gnupg/scdaemon.conf" = lib.mkIf (!relay.enable) {
    text = ''
      disable-ccid
      pcsc-shared
    '';
  };

  # The remote host owns the card and its agent. gpg talks to the socket a
  # local agent would hold; each connection opens its own TCP connection to the
  # remote relay, so a stream lost to suspend or a relay restart affects only
  # the request that was using it. Not bound to the graphical session, so SSH
  # logins get the socket too.
  systemd.user.sockets.gpg-agent-relay = lib.mkIf relay.enable {
    Unit.Description = "Remote gpg-agent relay socket";
    Socket = {
      ListenStream = "%t/gnupg/S.gpg-agent";
      SocketMode = "0600";
      DirectoryMode = "0700";
      Accept = true;
    };
    Install.WantedBy = [ "sockets.target" ];
  };
  systemd.user.services."gpg-agent-relay@" = lib.mkIf relay.enable {
    Unit.Description = "Remote gpg-agent relay connection";
    Service = {
      ExecStart = "${pkgs.socat}/bin/socat STDIO TCP:${relay.endpoint},connect-timeout=5";
      StandardInput = "socket";
      StandardOutput = "socket";
    };
  };

  # pinentry_mac pre-ticks "Save in Keychain" unless this is false
  # (AppDelegate.m registers UseKeychain = YES), so saving the card PIN
  # stays the user's choice on each prompt.
  targets.darwin.defaults."org.gpgtools.pinentry-mac" = lib.mkIf (config.my.kind == "darwin") {
    UseKeychain = false;
  };
}
