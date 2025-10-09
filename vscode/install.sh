#/env/env sh

_CURR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$_CURR_DIR" || exit 1

cat "$_CURR_DIR/extensions.txt" | xargs -L 1 code --install-extension
