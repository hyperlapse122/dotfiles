case ":${PATH-}:" in
    *:"$HOME/.local/bin":*) ;;
    *) PATH="$HOME/.local/bin${PATH:+:$PATH}" ;;
esac
export PATH

if [ "$(uname -s)" = Darwin ]; then
    dotfiles_build="$HOME/.local/share/dotfiles/build"
    if [ -r "$dotfiles_build/DOTNET_ROOT" ]; then
        IFS= read -r DOTNET_ROOT < "$dotfiles_build/DOTNET_ROOT"
        export DOTNET_ROOT
    fi
    if [ -r "$dotfiles_build/CARGO_HOME" ]; then
        IFS= read -r CARGO_HOME < "$dotfiles_build/CARGO_HOME"
        export CARGO_HOME
    fi
    if [ -r "$dotfiles_build/RUSTUP_HOME" ]; then
        IFS= read -r RUSTUP_HOME < "$dotfiles_build/RUSTUP_HOME"
        export RUSTUP_HOME
    fi
    if [ -r "$dotfiles_build/VCPKG_ROOT" ]; then
        IFS= read -r VCPKG_ROOT < "$dotfiles_build/VCPKG_ROOT"
        export VCPKG_ROOT
    fi
    for dotfiles_directory in "$dotfiles_build/bin" "${VCPKG_ROOT-}" "${CARGO_HOME:+$CARGO_HOME/bin}" "${DOTNET_ROOT-}"; do
        [ -d "$dotfiles_directory" ] || continue
        case ":$PATH:" in *:"$dotfiles_directory":*) ;; *) PATH="$dotfiles_directory:$PATH";; esac
    done
    export PATH
    unset dotfiles_build dotfiles_directory
fi
