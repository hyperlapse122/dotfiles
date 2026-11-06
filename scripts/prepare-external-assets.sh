#!/bin/sh
set -efu

fail() { printf '%s\n' "External asset preparation failed: $*" >&2; exit 1; }
[ "$#" -ge 5 ] && [ "$#" -le 6 ] || fail 'Expected manifest, roots, destination, cache, chezmoi, and optional mode.'
manifest=$1
roots=$2
destination=$3
cache=$4
chezmoi=$5
mode=${6:-normal}
case "$mode" in normal|verify|refresh) ;; *) fail "Invalid mode: $mode" ;; esac
[ -s "$roots" ] || exit 0
[ -f "$manifest" ] || fail 'External manifest is missing.'
case "$(uname -s)" in
    Darwin) checksum() { shasum -a 256 | awk '{print $1}'; } ;;
    Linux) checksum() { sha256sum | awk '{print $1}'; } ;;
    *) fail 'Requires Linux or macOS.' ;;
esac
tab=$(printf '\t')
awk -F '\t' '
    NF != 3 || $1 == "" || $1 ~ /^\// || $1 ~ /\\/ ||
    $1 ~ /(^|\/)\.\.?($|\/)/ || $1 ~ /\/\// ||
    ($2 != "file" && $2 != "directory") || ($3 != "true" && $3 != "false") ||
    seen[$1]++ { exit 1 }
' "$roots" || fail 'Invalid managed root list.'

mkdir -p "$cache" "$destination"
cache=$(cd "$cache" && pwd -P)
destination=$(cd "$destination" && pwd -P)
key=$({ cat "$manifest"; printf '\n'; cat "$roots"; } | checksum)
case "$key" in *[!a-f0-9]*|'') fail 'Invalid cache generation.' ;; esac
generation=$cache/generations/$key
[ ! -L "$cache/generations" ] && [ ! -L "$generation" ] || fail 'Cache generation is a symlink.'
mkdir -p "$generation/source"
tree=$generation/tree
[ ! -L "$tree" ] && [ ! -L "$generation/source" ] || fail 'Cache source or tree is a symlink.'
config=$cache/config.toml
[ ! -L "$config" ] || fail 'Cache configuration is a symlink.'
: > "$config"
cp "$manifest" "$generation/source/.chezmoiexternal.toml"
temporary=$(mktemp -d "$generation/check.XXXXXX")
cleanup() { rm -rf "$temporary"; }
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

# Reject links in installed parent components before reading, copying, or pruning.
assert_parent() {
    base=$1
    relative=$2
    parent=${relative%/*}
    [ "$parent" != "$relative" ] || return 0
    current=$base
    old_ifs=$IFS
    IFS=/
    set -- $parent
    IFS=$old_ifs
    for component do
        current=$current/$component
        [ ! -L "$current" ] || fail "Managed parent is a symlink: $current"
    done
}
if stat -c '%s' "$manifest" >/dev/null 2>&1; then
    stat_format='%n|%F|%s|%y|%a|%N'
    stat_style=-c
else
    stat_format='%N|%HT|%z|%.9Fm|%Lp|%Y'
    stat_style=-f
fi
stat_record() { stat "$stat_style" "$stat_format" "$1"; }

record() {
    snapshot_base=$1
    snapshot_relative=$2
    snapshot_path=$snapshot_base/$snapshot_relative
    printf '%s\t' "$snapshot_relative"
    if [ -L "$snapshot_path" ]; then
        stat_record "$snapshot_path"
        printf 'link\t%s\t%s\n' "$snapshot_relative" "$(readlink "$snapshot_path")"
    elif [ -e "$snapshot_path" ]; then
        stat_record "$snapshot_path"
    else
        printf 'missing\n'
    fi
}

snapshot() {
    snapshot_root=$1
    snapshot_destination=$2
    while IFS="$tab" read -r relative kind exact || [ -n "$relative" ]; do
        assert_parent "$snapshot_root" "$relative"
        if [ "$kind" = directory ] && [ -d "$snapshot_root/$relative" ] &&
            [ ! -L "$snapshot_root/$relative" ] &&
            { [ "$snapshot_destination" = false ] || [ "$exact" = true ]; }; then
            # A single stat process covers a directory batch without payload reads.
            find "$snapshot_root/$relative" -exec stat "$stat_style" "$stat_format" {} + | LC_ALL=C sort
        else
            record "$snapshot_root" "$relative"
        fi
        if [ "$kind" = directory ] && [ "$snapshot_destination" = true ] && [ "$exact" = false ]; then
            # Non-exact directories only own members present in prepared assets.
            enumerate=$tree/$relative
            if [ -d "$enumerate" ] && [ ! -L "$enumerate" ]; then
                find "$enumerate" -mindepth 1 -print | LC_ALL=C sort |
                    while IFS= read -r entry; do
                        child=${entry#"$enumerate"/}
                        record "$snapshot_root" "$relative/$child"
                    done
            fi
        fi
    done < "$roots"
}

snapshot "$tree" false > "$temporary/cache.snapshot"
prepare=false
if [ "$mode" != normal ] || [ ! -f "$generation/prepared" ] ||
    [ ! -f "$generation/cache.snapshot" ] ||
    ! cmp -s "$temporary/cache.snapshot" "$generation/cache.snapshot"; then
    prepare=true
fi
if "$prepare"; then
    printf '%s\n' 'Preparing external assets.'
    # The generated tree is disposable and cannot be the destination or cache root.
    case "$tree" in "$cache"/generations/*/tree) ;; *) fail 'Unsafe cache tree.' ;; esac
    [ ! -L "$tree" ] || fail 'Cache tree is a symlink.'
    rm -f "$generation/prepared"
    rm -rf "$tree"
    mkdir -p "$tree"
    if [ "$mode" = refresh ]; then
        "$chezmoi" --config "$config" --config-format toml --source "$generation/source" \
            --destination "$tree" --cache "$cache/downloads" --persistent-state "$cache/state.boltdb" \
            --no-tty --refresh-externals=always apply --force --exclude=scripts
    else
        "$chezmoi" --config "$config" --config-format toml --source "$generation/source" \
            --destination "$tree" --cache "$cache/downloads" --persistent-state "$cache/state.boltdb" \
            --no-tty apply --force --exclude=scripts
    fi
    while IFS="$tab" read -r relative kind exact || [ -n "$relative" ]; do
        if [ "$kind" = directory ]; then
            [ -d "$tree/$relative" ] && [ ! -L "$tree/$relative" ] ||
                fail "Prepared directory is missing: $relative"
        else
            [ -f "$tree/$relative" ] || [ -L "$tree/$relative" ] ||
                fail "Prepared file is missing: $relative"
        fi
    done < "$roots"
    snapshot "$tree" false > "$temporary/cache.snapshot"
    cp "$temporary/cache.snapshot" "$generation/cache.snapshot"
    : > "$generation/prepared"
fi

snapshot "$destination" true > "$temporary/destination.snapshot"
if [ "$mode" = normal ] && ! "$prepare" &&
    [ -f "$generation/destination.snapshot" ] &&
    cmp -s "$temporary/destination.snapshot" "$generation/destination.snapshot"; then
    printf '%s\n' 'Reusing prepared external assets.'
    exit 0
fi

copy_file() {
    source_file=$1
    target_file=$2
    [ ! -d "$target_file" ] || [ -L "$target_file" ] ||
        fail "Expected file but found directory: $target_file"
    mkdir -p "$(dirname "$target_file")"
    copy_temp=$(mktemp "$(dirname "$target_file")/.dotfiles-asset.XXXXXX")
    rm -f "$copy_temp"
    if ! cp -Pp "$source_file" "$copy_temp"; then
        rm -f "$copy_temp"
        fail "Cannot copy $source_file"
    fi
    [ ! -L "$target_file" ] || rm -f "$target_file"
    mv -f "$copy_temp" "$target_file"
}

while IFS="$tab" read -r relative kind exact || [ -n "$relative" ]; do
    assert_parent "$destination" "$relative"
    source_path=$tree/$relative
    target_path=$destination/$relative
    if [ "$kind" = file ]; then
        copy_file "$source_path" "$target_path"
    elif [ "$exact" = true ]; then
        mkdir -p "$(dirname "$target_path")"
        replacement=$(mktemp -d "$(dirname "$target_path")/.dotfiles-assets.XXXXXX")
        if ! cp -RPp "$source_path/." "$replacement"; then
            rm -rf "$replacement"
            fail "Cannot stage directory $relative"
        fi
        # Only an explicitly declared exact root can be replaced recursively.
        case "$target_path" in "$destination"/*) ;; *) fail 'Unsafe managed directory.' ;; esac
        if [ -L "$target_path" ]; then rm -f "$target_path"; else rm -rf "$target_path"; fi
        mv "$replacement" "$target_path"
    else
        [ ! -L "$target_path" ] || fail "Managed directory is a symlink: $target_path"
        mkdir -p "$target_path"
        find "$source_path" -mindepth 1 -print | LC_ALL=C sort |
            while IFS= read -r entry; do
                child=${entry#"$source_path"/}
                assert_parent "$destination" "$relative/$child"
                if [ -d "$entry" ] && [ ! -L "$entry" ]; then
                    [ ! -L "$target_path/$child" ] || fail 'Managed directory is a symlink.'
                    mkdir -p "$target_path/$child"
                else
                    copy_file "$entry" "$target_path/$child"
                fi
            done
    fi
done < "$roots"
snapshot "$destination" true > "$temporary/destination.snapshot"
mv -f "$temporary/destination.snapshot" "$generation/destination.snapshot"

