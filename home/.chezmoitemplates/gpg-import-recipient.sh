{{- $gpg := includeTemplate "gpg-settings" . | fromJson -}}
#!/bin/sh
set -eu
gpg='{{ $gpg.program | replace "'" "'\\''" }}'
recipient='{{ .gpgRecipient | replace "'" "'\\''" }}'
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT HUP INT TERM
cat > "$scratch/recipient.asc" <<'DOTFILES_PUBLIC_KEY'
{{ .gpgRecipientPublicKey }}
DOTFILES_PUBLIC_KEY

# Inspection can create keyring files, so use a disposable home first.
primary_fingerprint() {
    awk -F: '
        $1 == "sec" { invalid = 1 }
        $1 == "pub" { primary = 1; count++; next }
        primary && $1 == "fpr" { fingerprint = $10; primary = 0 }
        END { if (invalid || count != 1 || fingerprint == "") exit 1; print fingerprint }
    '
}
if ! "$gpg" --no-options --batch --no-autostart --no-auto-check-trustdb \
    --homedir "$scratch" --with-colons --import-options show-only \
    --import "$scratch/recipient.asc" > "$scratch/inspection"; then
    printf 'Cannot verify the public GPG recipient fingerprint.\n' >&2
    exit 1
fi
artifact="$(primary_fingerprint < "$scratch/inspection")" || artifact=''
if [ "$artifact" != "$recipient" ]; then
    printf 'Public GPG recipient fingerprint does not match the configured recipient.\n' >&2
    exit 1
fi
current=''
if "$gpg" --no-options --batch --no-autostart --no-auto-check-trustdb \
    --with-colons --list-keys "$recipient" > "$scratch/existing" 2>/dev/null; then
    current="$(primary_fingerprint < "$scratch/existing")" || current=''
fi
if [ "$current" = "$recipient" ]; then
    exit 0
fi
"$gpg" --no-options --batch --no-autostart --no-auto-check-trustdb --import "$scratch/recipient.asc"
"$gpg" --no-options --batch --no-autostart --no-auto-check-trustdb \
    --with-colons --list-keys "$recipient" > "$scratch/imported"
current="$(primary_fingerprint < "$scratch/imported")" || current=''
if [ "$current" != "$recipient" ]; then
    printf 'Imported GPG recipient fingerprint verification failed.\n' >&2
    exit 1
fi
