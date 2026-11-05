#!/bin/sh
# This helper is called only by explicit macos-build tasks, never preparation.
set -eu
[ "$(uname -s)" = Darwin ] || exit 0

fail() { printf '%s\n' "$*" >&2; exit 1; }
state="$HOME/.local/share/dotfiles/build"
publish() {
    case "$2" in /*) ;; *) fail "$1 must be an absolute path.";; esac
    mkdir -p "$state"
    printf '%s\n' "$2" > "$state/$1"
}

case "${1-}" in
preflight)
    [ "$(uname -m)" = arm64 ] || fail 'macos-build requires native Apple Silicon; Rosetta is unsupported.'
    version=$(sw_vers -productVersion)
    major=${version%%.*}
    case "$major" in ''|*[!0-9]*) fail 'Cannot identify the macOS version.';; esac
    [ "$major" -ge 15 ] || fail 'macos-build requires macOS 15 or later.'
    xcode-select -p >/dev/null || fail 'Install and select Apple Command Line Tools before applying.'
    xcrun --find clang >/dev/null || fail 'The selected Apple developer tools have no clang.'
    xcrun --show-sdk-path >/dev/null || fail 'The selected Apple developer tools have no macOS SDK.'
    ;;
dotnet)
    major=${2-}
    case "$major" in 8|10) ;; *) fail 'Specify SDK 8 or 10.';; esac
    root=${DOTNET_ROOT-}
    [ -n "$root" ] && [ -x "$root/dotnet" ] || fail 'The mise task must supply a usable DOTNET_ROOT.'
    sdks=$("$root/dotnet" --list-sdks)
    printf '%s\n' "$sdks" | grep -Eq "^$major\.[0-9]+\.[^ ]+ \[" || fail "SDK $major is missing from the shared mise DOTNET_ROOT."
    publish DOTNET_ROOT "$root"
    printf '%s\n' "$sdks"
    ;;
rust)
    : "${CARGO_HOME:?The mise Rust task must supply CARGO_HOME}"
    : "${RUSTUP_HOME:?The mise Rust task must supply RUSTUP_HOME}"
    : "${RUSTUP_TOOLCHAIN:?The mise Rust task must supply RUSTUP_TOOLCHAIN}"
    info=$("$CARGO_HOME/bin/rustc" --version --verbose)
    printf '%s\n' "$info" | grep -Fx 'host: aarch64-apple-darwin' >/dev/null || fail 'Rust must use the native aarch64-apple-darwin host.'
    targets=$("$CARGO_HOME/bin/rustup" target list --installed --toolchain "$RUSTUP_TOOLCHAIN")
    printf '%s\n' "$targets" | grep -Fx aarch64-apple-darwin >/dev/null || fail 'Rust is missing the aarch64-apple-darwin target.'
    toolchains=$("$CARGO_HOME/bin/rustup" toolchain list)
    if ! printf '%s\n' "$toolchains" | grep -Eq '\([^)]*default[^)]*\)'; then
        "$CARGO_HOME/bin/rustup" default "$RUSTUP_TOOLCHAIN"
    fi
    publish CARGO_HOME "$CARGO_HOME"
    publish RUSTUP_HOME "$RUSTUP_HOME"
    printf '%s\n' "$info"
    ;;
tools)
    mkdir -p "$state/bin"
    # Root mise declarations supply Python and PowerShell in this task too.
    for tool in cmake ninja python pwsh; do
        executable=$(command -v "$tool") || fail "The mise task must supply $tool."
        case "$executable" in /*) ;; *) fail "$tool must resolve to an absolute executable.";; esac
        "$executable" --version
        ln -sf "$executable" "$state/bin/$tool"
    done
    ;;
vcpkg)
    repository=${2-}
    revision=${3-}
    [ "$repository" = https://github.com/microsoft/vcpkg.git ] || fail 'Use the official Microsoft vcpkg repository.'
    case "$revision" in ''|-*|*[!a-zA-Z0-9._-]*) fail 'Use an exact vcpkg tag or commit.';; esac
    root="$HOME/.local/share/dotfiles/vcpkg"
    if [ ! -d "$root/.git" ]; then
        [ ! -e "$root" ] || [ -z "$(ls -A "$root")" ] || fail 'Refusing unrelated vcpkg directory.'
        git clone --origin origin "$repository" "$root"
    fi
    [ "$(git -C "$root" remote get-url origin)" = "$repository" ] || fail 'The managed vcpkg checkout has an unexpected origin.'
    [ "$(git -C "$root" rev-parse --show-toplevel)" = "$root" ] || fail 'The managed vcpkg path is not its repository root.'
    [ -z "$(git -C "$root" status --porcelain --untracked-files=normal)" ] || fail 'Preserve local vcpkg changes before applying.'
    case "$revision" in
        ????????????????????????????????????????) reference=$revision;;
        *) reference="refs/tags/$revision";;
    esac
    git -C "$root" fetch origin "$reference"
    commit=$(git -C "$root" rev-parse --verify 'FETCH_HEAD^{commit}')
    case "$commit" in *[!0-9a-fA-F]*|'') fail 'Git did not resolve the pinned vcpkg commit.';; esac
    [ "${#commit}" -eq 40 ] || fail 'Git did not resolve one full vcpkg commit.'
    if [ "${#revision}" -eq 40 ]; then
        [ "$commit" = "$revision" ] || fail 'Fetched vcpkg commit differs from its pin.'
    fi
    git -C "$root" checkout --detach "$commit"
    [ -f "$root/bootstrap-vcpkg.sh" ] && [ -f "$root/scripts/buildsystems/vcpkg.cmake" ] || fail 'Incomplete vcpkg checkout.'
    (cd "$root" && sh ./bootstrap-vcpkg.sh -disableMetrics)
    "$root/vcpkg" version
    publish VCPKG_ROOT "$root"
    ;;
*) fail 'Specify preflight, dotnet, rust, tools or vcpkg.';;
esac
