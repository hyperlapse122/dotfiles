{ pkgs }:

let
  manifest = builtins.fromJSON (builtins.readFile ./claude-code-manifest.json);
in
(pkgs.claude-code.override { inherit manifest; }).overrideAttrs (old: {
  # The native runtime's system store misses public issuers on macOS even when
  # curl trusts them. Keep system-only trust and supplement it with macOS's PEM
  # bundle; an explicitly supplied corporate CA bundle still takes precedence.
  postInstall =
    (old.postInstall or "")
    + pkgs.lib.optionalString pkgs.stdenv.hostPlatform.isDarwin ''
      wrapProgram $out/bin/claude --set-default NODE_EXTRA_CA_CERTS /etc/ssl/cert.pem
    '';

  # A host that trusts a TLS inspection CA sets NODE_EXTRA_CA_CERTS to its own
  # bundle, so the wrapper must only default it. Swap the wrapped binary for a
  # stub that prints the variable and run the real wrapper with and without it.
  postInstallCheck =
    (old.postInstallCheck or "")
    + pkgs.lib.optionalString pkgs.stdenv.hostPlatform.isDarwin ''
      wrapped=$out/bin/.claude-wrapped
      mv "$wrapped" "$wrapped.real"
      printf '#!/bin/sh\nprintf %%s "$NODE_EXTRA_CA_CERTS"\n' >"$wrapped"
      chmod +x "$wrapped"
      [ "$(env -u NODE_EXTRA_CA_CERTS $out/bin/claude)" = /etc/ssl/cert.pem ] ||
        { echo "the claude wrapper does not default NODE_EXTRA_CA_CERTS to /etc/ssl/cert.pem" >&2; exit 1; }
      [ "$(NODE_EXTRA_CA_CERTS=/session/bundle.crt $out/bin/claude)" = /session/bundle.crt ] ||
        { echo "the claude wrapper overrides a NODE_EXTRA_CA_CERTS the session sets" >&2; exit 1; }
      mv -f "$wrapped.real" "$wrapped"
    '';
})
