#!/usr/bin/env zsh

if ! command -v op &> /dev/null || ! command -v gpg &> /dev/null; then
    echo "Error: Required commands 'op' and/or 'gpg' are not available." >&2
    exit 1
fi

op read "op://tjlmijoc5qxj6vypdnvxf6s2sq/gmwqu34rldszc6qtas2i3ejiaq/gpg_private.asc" | gpg --batch --import
