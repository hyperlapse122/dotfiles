# 1Password legacy autostart entry removal checklist (operator-run, not automated)

> **Label:** 1Password legacy autostart entry removal checklist. This document is
> manual operator guidance for hosts that previously received the managed
> `~/.config/autostart/1password.desktop`. Chezmoi does not run these commands,
> and this source change adds no teardown or revert script.

1Password 8.12 writes its own login entry at
`~/.config/autostart/com.onepassword.OnePassword.desktop`. The dotfiles now seed
that file once and no longer manage `1password.desktop`. Chezmoi does not delete
the old file: when the file changed after chezmoi wrote it, a chezmoi removal
(`.chezmoiremove` or a `remove_` source) stops at the
`has changed since chezmoi last wrote it?` prompt and aborts the whole apply.

## 1. Apply the revised source

- Run your normal `chezmoi apply` from the revised source.
- The apply must finish without a prompt about a 1Password autostart file.

## 2. Confirm the new entry exists

```sh
test -f "$HOME/.config/autostart/com.onepassword.OnePassword.desktop"
```

If the command fails, do not continue. Rerun the apply, or turn on
"Start at login" in the 1Password settings.

## 3. Remove the legacy entry

```sh
rm -f -- "$HOME/.config/autostart/1password.desktop"
```

A missing file is expected on a host that never received the old entry.

## 4. Verify the cleanup

```sh
set -eu
test ! -e "$HOME/.config/autostart/1password.desktop"
test -f "$HOME/.config/autostart/com.onepassword.OnePassword.desktop"
if chezmoi managed --include files | grep -qxF '.config/autostart/1password.desktop'; then
  printf 'chezmoi still manages the legacy entry\n' >&2
  exit 1
fi
```

All commands must exit successfully.
