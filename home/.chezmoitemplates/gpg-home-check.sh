{{- $gpg := includeTemplate "gpg-settings" . | fromJson -}}
#!/bin/sh
# file gpg-settings sha256: {{ include ".chezmoitemplates/gpg-settings" | sha256sum }}
# file gpg-home sha256: {{ include ".chezmoitemplates/gpg-home" | sha256sum }}
# data gpg.program sha256: {{ dict "program" $gpg.program | toJson | sha256sum }}
set -eu
gpgconf='{{ printf "%s/gpgconf" (dir $gpg.program) | replace "'" "'\\''" }}'
expected='{{ includeTemplate "gpg-home" . | replace "'" "'\\''" }}'
if [ -L "$expected" ]; then
    printf "Refusing to replace linked GPG home '%s'. Reconcile the GPG home before applying.\n" "$expected" >&2
    exit 1
fi
actual="$("$gpgconf" --list-dirs homedir)"
if [ "${actual%/}" != "${expected%/}" ]; then
    printf "GPG uses '%s', but these dotfiles manage '%s'. Reconcile the GPG home before applying.\n" "$actual" "$expected" >&2
    exit 1
fi
