#!/bin/sh
set -eu
[ "$(uname -s)" = Linux ] || exit 0

fail() { printf '%s\n' "$*" >&2; exit 1; }
script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
python3 "$script_directory/linux-platform.py" >/dev/null || fail 'Requires a supported Ubuntu Studio host; run the host probe for details.'

state="$HOME/.local/share/dotfiles/build"
publish() {
    case "$2" in /*) ;; *) fail "$1 must be an absolute path.";; esac
    mkdir -p "$state"
    printf '%s\n' "$2" > "$state/$1"
}

case "${1-}" in
preflight)
    for compiler in cc c++; do
        command -v "$compiler" >/dev/null || fail "Run mise run apply from the inspected checkout to install the native $compiler compiler."
        target=$("$compiler" -dumpmachine) || fail "Cannot inspect $compiler target."
        [ "$target" = x86_64-linux-gnu ] || fail "$compiler must target native x86_64-linux-gnu."
    done
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
    rustc=$(command -v rustc) || fail 'The mise Rust task must supply rustc.'
    case "$rustc" in /*) ;; *) fail 'rustc must resolve to an absolute executable.';; esac
    info=$("$rustc" --version --verbose)
    printf '%s\n' "$info" | grep -Fx 'host: x86_64-unknown-linux-gnu' >/dev/null || fail 'Rust must use the native x86_64-unknown-linux-gnu host.'
    rustup=$(command -v rustup) || fail 'The mise Rust task must supply rustup.'
    cargo=$(command -v cargo) || fail 'The mise Rust task must supply cargo.'
    for executable in "$rustup" "$cargo"; do
        case "$executable" in /*) ;; *) fail 'Rust proxies must resolve to absolute executables.';; esac
    done
    targets=$("$rustup" target list --installed --toolchain "$RUSTUP_TOOLCHAIN")
    printf '%s\n' "$targets" | grep -Fx x86_64-unknown-linux-gnu >/dev/null || fail 'Rust is missing the x86_64-unknown-linux-gnu target.'
    toolchains=$("$rustup" toolchain list)
    if ! printf '%s\n' "$toolchains" | grep -Eq '\([^)]*default[^)]*\)'; then
        "$rustup" default "$RUSTUP_TOOLCHAIN"
    fi
    publish CARGO_HOME "$CARGO_HOME"
    publish RUSTUP_HOME "$RUSTUP_HOME"
    mkdir -p "$state/bin"
    ln -sf "$rustc" "$state/bin/rustc"
    ln -sf "$rustup" "$state/bin/rustup"
    ln -sf "$cargo" "$state/bin/cargo"
    printf '%s\n' "$info"
    ;;
tools|kubernetes)
    mkdir -p "$state/bin"
    tools="cmake ninja python pwsh"
    [ "$1" != kubernetes ] || tools="minikube kubectl"
    for tool in $tools; do
        executable=$(command -v "$tool") || fail "The mise task must supply $tool."
        case "$executable" in /*) ;; *) fail "$tool must resolve to an absolute executable.";; esac
        case "$tool" in
            minikube) "$executable" version;;
            kubectl) "$executable" version --client;;
            *) "$executable" --version;;
        esac
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
*) fail 'Specify preflight, dotnet, rust, tools, kubernetes or vcpkg.';;
esac
