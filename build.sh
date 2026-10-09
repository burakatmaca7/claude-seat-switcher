#!/bin/sh
# Builds "Claude Seat Switcher.app" into ./build from source.
#   ./build.sh            build only
#   ./build.sh --install  build and copy to /Applications
set -eu
cd "$(dirname "$0")"

APP_NAME="Claude Seat Switcher"
BUNDLE_ID="io.github.burakatmaca7.claude-seat-switcher"
VERSION=$(sed -n 's/.*static let version = "\(.*\)".*/\1/p' Sources/ClaudeSeatSwitcher/AppInfo.swift)
[ -n "$VERSION" ] || { echo "Could not read the app version from AppInfo.swift" >&2; exit 1; }

# One architecture at a time, then join: building both in one invocation fails on some Xcode versions.
for ARCH in arm64 x86_64; do
    swift build -c release --arch "$ARCH"
done
mkdir -p build
BIN="build/ClaudeSeatSwitcher-universal"
lipo -create -output "$BIN" \
    "$(swift build -c release --arch arm64 --show-bin-path)/ClaudeSeatSwitcher" \
    "$(swift build -c release --arch x86_64 --show-bin-path)/ClaudeSeatSwitcher"

APP="build/$APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/ClaudeSeatSwitcher"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key><string>ClaudeSeatSwitcher</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHumanReadableCopyright</key><string>MIT License. Unofficial; not affiliated with Anthropic.</string>
</dict>
</plist>
PLIST

# Ad-hoc signature: required to run on Apple silicon. Not notarized.
codesign --force --sign - "$APP"
echo "Built: $APP ($VERSION)"

if [ "${1:-}" = "--install" ]; then
    rm -rf "/Applications/$APP_NAME.app"
    cp -R "$APP" "/Applications/"
    echo "Installed: /Applications/$APP_NAME.app"
fi
