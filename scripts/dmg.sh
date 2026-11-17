#!/bin/zsh
# Packs build/Frontier.app into build/Frontier-<version>.dmg with a drag-to-Applications layout.
set -euo pipefail
cd "$(dirname "$0")/.."
app=build/Frontier.app
[[ -d "$app" ]] || { echo "build/Frontier.app is missing; run 'make app' first" >&2; exit 1; }
version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$app/Contents/Info.plist")
dmg=build/Frontier-$version.dmg
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
cp -R "$app" "$stage/"
ln -s /Applications "$stage/Applications"
rm -f "$dmg"
hdiutil create -quiet -volname "Frontier" -srcfolder "$stage" -fs HFS+ -format UDZO -imagekey zlib-level=9 "$dmg"
echo "$dmg"
