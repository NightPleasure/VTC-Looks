#!/usr/bin/env bash
set -euo pipefail
PLUGIN_PATH="${1:-$HOME/Library/Application Support/Adobe/Common/Plug-ins/7.0/MediaCore/VTC Looks/VTC_Looks_AdobePF_Clean.plugin}"
BIN="$PLUGIN_PATH/Contents/MacOS/$(basename "$PLUGIN_PATH" .plugin)"
RSRC="$PLUGIN_PATH/Contents/Resources/$(basename "$PLUGIN_PATH" .plugin).rsrc"

printf "Plugin path: %s\n" "$PLUGIN_PATH"
ls -R "$PLUGIN_PATH"

printf "\nfile (binary):\n" && file "$BIN"
printf "\nfile (rsrc):\n" && file "$RSRC"

printf "\notool -L:\n" && otool -L "$BIN"

printf "\nnm entrypoints:\n" && nm -gjU "$BIN" | egrep -i "(EffectMain|PluginMain|Entry|Main)" || true

printf "\ncodesign -dv:\n" && codesign -dv --verbose=4 "$PLUGIN_PATH" || true

printf "\nxattr -lr:\n" && xattr -lr "$PLUGIN_PATH" || true

printf "\nstrings PiPL (rsrc):\n" && strings "$RSRC" | head -n 40
