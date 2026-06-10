# Chromium external extensions (user-scope auto-install)

Files here are symlinked to `~/.config/chromium/External Extensions/` by the
`home/.config/**/*` glob in [`../../../../install.linux.yaml`](../../../../install.linux.yaml).
On startup Chromium scans that directory for `<extension-id>.json` files and
auto-installs each referenced extension from its update URL. This is the
user-scope, no-root equivalent of `code --install-extension`.

## Chromium only — not Google Chrome on Linux

The per-user external-extensions provider is `CHROMIUM_BRANDING`-gated on Linux
(see `chrome/browser/extensions/external_provider_impl.cc` — the
`DIR_USER_EXTERNAL_EXTENSIONS` provider is compiled in for
`IS_MAC || ((IS_LINUX || IS_CHROMEOS) && CHROMIUM_BRANDING)`). Google Chrome on
Linux does **not** compile it in and only reads the system-wide
`/opt/google/chrome/extensions/` dir. That is why `scripts/linux/install-packages.sh`
installs `chromium`, not `google-chrome-stable`. On macOS the path is
`~/Library/Application Support/Chromium/External Extensions/` instead, and Chrome
on macOS does support it.

## Add an extension

1. Find the extension ID — the 32-character string in its Chrome Web Store URL:
   `https://chromewebstore.google.com/detail/<name>/<EXTENSION_ID>`.
2. Create `<EXTENSION_ID>.json` in this directory pointing at the Web Store
   update endpoint:

   ```json
   {
     "external_update_url": "https://clients2.google.com/service/update2/crx"
   }
   ```

3. Re-run `./install.sh` (or dotbot) to symlink the new file, then restart
   Chromium — it installs the extension on next launch.

A ready-to-use template is in
[`cjpalhdlnbpafiamejdnhcphjbkeiagm.json.example`](cjpalhdlnbpafiamejdnhcphjbkeiagm.json.example)
(uBlock Origin). Copy it to `cjpalhdlnbpafiamejdnhcphjbkeiagm.json` to enable.

## Notes

- Chromium only reads files ending in `.json`. This `README.md` and the
  `*.json.example` template are ignored, so they are safe to keep here even
  though dotbot also symlinks them into the live directory.
- Extensions installed this way can still be disabled or removed by the user,
  unlike the root `ExtensionInstallForcelist` enterprise policy, which pins them.
- No real extension ships in this repo by default — only the example template.
