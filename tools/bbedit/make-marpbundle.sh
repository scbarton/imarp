#!/bin/bash
# Packages a Marp deck (.md/.marp) into a .marpbundle next to it, in the flat
# layout the app renders on-device (see MarpBundleLoader.swift):
#
#   MyDeck.marpbundle/
#     source.md
#     theme.css   (if a theme.css sits next to the source file)
#     assets/     (if an assets/ folder sits next to the source file)
#
# Re-running on the same source updates the bundle in place. Any existing
# source.html cache is dropped so the app re-renders from the (possibly
# changed) source instead of showing a stale cached version.
set -euo pipefail

src="${1:?usage: make-marpbundle.sh <path-to-deck.md>}"
[ -f "$src" ] || { echo "File not found: $src" >&2; exit 1; }

dir="$(cd "$(dirname "$src")" && pwd)"
base="$(basename "$src")"
name="${base%.*}"

bundle="$dir/$name.marpbundle"

mkdir -p "$bundle"
cp "$src" "$bundle/source.md"

if [ -f "$dir/theme.css" ]; then
    cp "$dir/theme.css" "$bundle/theme.css"
fi

if [ -d "$dir/assets" ]; then
    rm -rf "$bundle/assets"
    cp -R "$dir/assets" "$bundle/assets"
fi

rm -f "$bundle/source.html"

echo "$bundle"
