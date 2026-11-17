#!/bin/zsh
# Assembles build/Frontier.app from the release binary and Resources, then ad-hoc signs it.
set -euo pipefail
cd "$(dirname "$0")/.."
bin=$(swift build -c release ${=SDK_ARGS:-} --show-bin-path)/Frontier
app=build/Frontier.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin" "$app/Contents/MacOS/Frontier"
cp -R Sources/Frontier/Resources/Fonts Sources/Frontier/Resources/Art Sources/Frontier/Resources/Video "$app/Contents/Resources/"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Frontier</string>
    <key>CFBundleDisplayName</key><string>Frontier</string>
    <key>CFBundleIdentifier</key><string>local.frontier.app</string>
    <key>CFBundleExecutable</key><string>Frontier</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>Personal fan project. Not affiliated with Rockstar Games.</string>
</dict>
</plist>
PLIST
codesign --force --sign - "$app" >/dev/null 2>&1
echo "$app"
