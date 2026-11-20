{
  config,
  lib,
  pkgs,
  ...
}:

let
  gpgTools = import ../../../packages/gpg-tools.nix { inherit pkgs; };
in
{
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
    };
  };

  services.gpg-agent = {
    enable = true;
    pinentry.package = gpgTools.pinentryKeyring;
    # Off Darwin this also adds the systemd socket the supervised agent serves
    # SSH on. On Darwin, gpg-agent --supervised takes only systemd's sockets,
    # so launchd cannot hand it an SSH socket; a client-started agent serves
    # SSH there instead, and the ssh-agent-mux launcher starts it.
    enableSshSupport = config.my.kind != "darwin";
    # zsh exports GPG_TTY itself (shell.nix). With SSH support, this hook
    # would also run updatestartuptty from every shell, starting an agent
    # ahead of Prezto's gpg module and moving SSH pinentry to that terminal.
    enableZshIntegration = false;
    extraConfig = ''
      allow-loopback-pinentry
      default-cache-ttl 0
      max-cache-ttl 0
    ''
    + lib.optionalString (config.my.kind == "darwin") ''
      enable-ssh-support
    '';
  };

  # enableSshSupport would export SSH_AUTH_SOCK from shells, systemd, and
  # D-Bus. gpg-agent is one member of the SSH key chain that ~/.ssh/config and
  # desktop-ssh assemble, so it must not replace the session's agent.
  sshAuthSock.enable = lib.mkForce false;

  # While launchd holds S.gpg-agent, every gpg client connects to the
  # supervised agent, so none ever starts the daemon that creates the SSH
  # socket. Without the job, the first client starts that daemon.
  launchd.agents.gpg-agent.enable = lib.mkIf (config.my.kind == "darwin") (lib.mkForce false);

  home.file.".gnupg/scdaemon.conf" = {
    text = ''
      disable-ccid
      pcsc-shared
    '';
  };

  # pinentry_mac pre-ticks "Save in Keychain" unless this is false
  # (AppDelegate.m registers UseKeychain = YES), so saving the card PIN
  # stays the user's choice on each prompt.
  targets.darwin.defaults."org.gpgtools.pinentry-mac" = lib.mkIf (config.my.kind == "darwin") {
    UseKeychain = false;
  };
}
