#!/bin/bash
# Packages a Marp deck (.md/.marp) into an .imarpbundle next to it, in the
# source-only layout the app renders on-device (see MarpBundleLoader.swift):
#
#   MyDeck.imarpbundle/
#     source/
#       deck.md
#       theme.css   (if a theme.css sits next to the source file)
#       assets/     (if an assets/ folder sits next to the source file)
#
# Re-running on the same source updates the bundle in place. Any existing
# rendered/ cache is dropped so the app re-renders from the (possibly
# changed) source instead of showing a stale cached version.
set -euo pipefail

src="${1:?usage: make-imarpbundle.sh <path-to-deck.md>}"
[ -f "$src" ] || { echo "File not found: $src" >&2; exit 1; }

dir="$(cd "$(dirname "$src")" && pwd)"
base="$(basename "$src")"
name="${base%.*}"

bundle="$dir/$name.imarpbundle"
source_dir="$bundle/source"

mkdir -p "$source_dir"
cp "$src" "$source_dir/deck.md"

if [ -f "$dir/theme.css" ]; then
    cp "$dir/theme.css" "$source_dir/theme.css"
fi

if [ -d "$dir/assets" ]; then
    rm -rf "$source_dir/assets"
    cp -R "$dir/assets" "$source_dir/assets"
fi

rm -rf "$bundle/rendered"

echo "$bundle"
