#!/usr/bin/env bash
# Builds Daymark.app into ./build. Pass --install to copy it to /Applications.
#
# Optional environment variables:
#   DAYMARK_UNIVERSAL=1      build one app for Apple Silicon and Intel Macs (arm64 + x86_64)
#   DAYMARK_VERSION=1.2.3    version shown in Finder / About (default: Resources/Info.plist)
#   DAYMARK_BUILD_NUMBER=42  build number (default: 1)
#   DAYMARK_SIGN=adhoc       never use a personal certificate (used for published releases)
#   INSTALL_DIR=…            where --install copies the app (default: /Applications)
set -euo pipefail
cd "$(dirname "$0")/.."

APP=build/Daymark.app
ARCH_ARGS=()
if [[ "${DAYMARK_UNIVERSAL:-}" == "1" ]]; then
    ARCH_ARGS=(--arch arm64 --arch x86_64)
fi
swift build -c release ${ARCH_ARGS[@]+"${ARCH_ARGS[@]}"}
BIN="$(swift build -c release ${ARCH_ARGS[@]+"${ARCH_ARGS[@]}"} --show-bin-path)/Daymark"

mkdir -p build
# Regenerate the icon when the icon script changes.
if [[ ! -f build/AppIcon.icns || scripts/make-icon.swift -nt build/AppIcon.icns ]]; then
    swift scripts/make-icon.swift build/AppIcon.icns
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Daymark"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
if [[ -n "${DAYMARK_VERSION:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${DAYMARK_VERSION#v}" "$APP/Contents/Info.plist"
fi
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${DAYMARK_BUILD_NUMBER:-1}" "$APP/Contents/Info.plist"
# Remove debug symbols: they include the builder's absolute file paths (e.g. their home folder).
# Must happen before signing, or the signature breaks.
strip -S "$APP/Contents/MacOS/Daymark"

# Sign with an Apple Development certificate when there is one: macOS then allows Notification
# Center, and the Keychain stops asking for access after every rebuild. Otherwise sign ad hoc.
IDENTITY=""
if [[ "${DAYMARK_SIGN:-}" != "adhoc" ]]; then
    IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | grep -m1 -E '"(Apple Development|Developer ID Application)' | sed -E 's/.*"(.*)"/\1/' || true)"
fi
if [[ -n "$IDENTITY" ]]; then
    codesign --force --sign "$IDENTITY" "$APP"
    echo "Signed with your ${IDENTITY%%:*} certificate"
else
    codesign --force --sign - "$APP"
    echo "Signed ad hoc (reminders use Daymark's own windows unless the app is signed with an Apple Development certificate)"
fi
echo "Built $APP ($(lipo -archs "$APP/Contents/MacOS/Daymark"))"

if [[ "${1:-}" == "--install" ]]; then
    DEST="${INSTALL_DIR:-/Applications}"
    rm -rf "$DEST/Daymark.app"
    cp -R "$APP" "$DEST/"
    echo "Installed to $DEST/Daymark.app"
fi
