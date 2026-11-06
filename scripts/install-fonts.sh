#!/bin/sh
set -eu

fail() { printf '%s\n' "Font installation failed: $*" >&2; exit 1; }
[ "$#" -eq 4 ] || fail 'Expected asset root, index path, font directory, and state path.'
asset_root=$1
index=$2
font_dir=$3
state=$4

case "$(uname -s)" in
    Linux)
        command -v fc-cache >/dev/null 2>&1 || fail 'Install fontconfig, then run chezmoi apply again.'
        checksum() { sha256sum "$1" | awk '{print $1}'; }
        refresh() { fc-cache "$font_dir"; }
        ;;
    Darwin)
        checksum() { shasum -a 256 "$1" | awk '{print $1}'; }
        refresh() { :; }
        ;;
    *) fail 'Requires Linux or macOS.' ;;
esac

[ -f "$index" ] || fail 'Font index is missing; run chezmoi apply again.'
awk -F '\t' '
    NF != 4 || $1 !~ /^[a-z][a-z0-9-]*$/ ||
    $2 !~ /^[A-Za-z0-9_.\/-]+$/ || $2 ~ /^\// || $2 ~ /\/\// ||
    $2 ~ /(^|\/)\.\.?($|\/)/ ||
    $3 !~ /^[A-Za-z0-9][A-Za-z0-9_.-]*\.ttf$/ ||
    length($4) != 64 || $4 ~ /[^a-f0-9]/ { exit 1 }
    { n = split($2, parts, "/"); if (parts[n] != $3 || seen[$1 "-" $3]++) exit 1 }
' "$index" || fail 'Invalid font index.'

if [ -f "$state" ]; then
    awk '
        !/^dotfiles-[a-z0-9-]+-[A-Za-z0-9][A-Za-z0-9_.-]*\.ttf$/ || seen[$0]++ { exit 1 }
    ' "$state" || fail 'Invalid owned-font manifest; refusing cleanup.'
fi

tab=$(printf '\t')
while IFS="$tab" read -r package member name expected || [ -n "$package" ]; do
    source=$asset_root/$package/$member
    [ -f "$source" ] || fail "Missing staged font: $package/$member"
    [ "$(checksum "$source")" = "$expected" ] || fail "Staged font checksum mismatch: $package/$member"
done < "$index"

mkdir -p "$font_dir" "$(dirname "$state")"
state_temp=$(mktemp "$(dirname "$state")/.dotfiles-fonts.XXXXXX")
copy_temp=
cleanup() {
    [ -z "$copy_temp" ] || rm -f "$copy_temp"
    [ -z "$state_temp" ] || rm -f "$state_temp"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

while IFS="$tab" read -r package member name expected || [ -n "$package" ]; do
    source=$asset_root/$package/$member
    destination=dotfiles-$package-$name
    printf '%s\n' "$destination" >> "$state_temp"
    if [ ! -f "$font_dir/$destination" ] || ! cmp -s "$source" "$font_dir/$destination"; then
        copy_temp=$(mktemp "$font_dir/.dotfiles-font.XXXXXX")
        cp "$source" "$copy_temp"
        chmod 644 "$copy_temp"
        mv -f "$copy_temp" "$font_dir/$destination"
        copy_temp=
    fi
done < "$index"

if [ -f "$state" ]; then
    while IFS= read -r name || [ -n "$name" ]; do
        if ! grep -F -x -q "$name" "$state_temp"; then
            rm -f "$font_dir/$name"
        fi
    done < "$state"
fi
refresh || fail 'Font discovery refresh failed; run chezmoi apply again.'
if [ ! -f "$state" ] || ! cmp -s "$state_temp" "$state"; then
    mv -f "$state_temp" "$state"
    state_temp=
fi
printf '%s\n' 'User fonts are available.'
