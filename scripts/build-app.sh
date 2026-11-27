#!/usr/bin/env bash
# Builds Daymark.app into ./build. Pass --install to copy it to /Applications.
set -euo pipefail
cd "$(dirname "$0")/.."

APP=build/Daymark.app
swift build -c release
BIN="$(swift build -c release --show-bin-path)/Daymark"

mkdir -p build
[[ -f build/AppIcon.icns ]] || swift scripts/make-icon.swift build/AppIcon.icns

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Daymark"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Sign with an Apple Development certificate when there is one: macOS then allows Notification
# Center, and the Keychain stops asking for access after every rebuild. Otherwise sign ad hoc.
IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | grep -m1 -E '"(Apple Development|Developer ID Application)' | sed -E 's/.*"(.*)"/\1/' || true)"
if [[ -n "$IDENTITY" ]]; then
    codesign --force --sign "$IDENTITY" "$APP"
    echo "Signed with your ${IDENTITY%%:*} certificate"
else
    codesign --force --sign - "$APP"
    echo "Signed ad hoc (no Apple Development certificate found; reminders use Daymark's own windows)"
fi
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
    DEST="${INSTALL_DIR:-/Applications}"
    rm -rf "$DEST/Daymark.app"
    cp -R "$APP" "$DEST/"
    echo "Installed to $DEST/Daymark.app"
fi
