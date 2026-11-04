case ":${PATH-}:" in
    *:"$HOME/.local/bin":*) ;;
    *) PATH="$HOME/.local/bin${PATH:+:$PATH}" ;;
esac
export PATH
