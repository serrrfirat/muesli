#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
SODIUM="$(brew --prefix libsodium)"
SQLCIPHER="$(brew --prefix sqlcipher)"
export PKG_CONFIG_PATH="$SODIUM/lib/pkgconfig:$SQLCIPHER/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
PACKAGE="$ROOT/native/MuesliNative"
swift build --package-path "$PACKAGE" --cache-path "$ROOT/.build/muesli-cache" -c debug --product MuesliNativeApp -j 4 \
  -Xcc "-I$SODIUM/include" -Xcc "-I$SQLCIPHER/include" \
  -Xlinker "-L$SODIUM/lib" -Xlinker "-L$SQLCIPHER/lib"
BIN="$(swift build --package-path "$PACKAGE" --cache-path "$ROOT/.build/muesli-cache" -c debug --show-bin-path)"
mkdir -p "$ROOT/dist"
STAGE="$(mktemp -d "$ROOT/dist/.hush-build.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
APP="$STAGE/Hush.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/MuesliNativeApp" "$APP/Contents/MacOS/Hush"
for framework in "$BIN"/*.framework; do
  [[ -d "$framework" ]] || continue
  ditto "$framework" "$APP/Contents/MacOS/$(basename "$framework")"
done
for dylib in "$BIN"/*.dylib; do
  [[ -f "$dylib" ]] || continue
  cp -RL "$dylib" "$APP/Contents/MacOS/$(basename "$dylib")"
done
for bundle in "$BIN"/*.bundle; do
  [[ -d "$bundle" ]] || continue
  ditto "$bundle" "$APP/Contents/Resources/$(basename "$bundle")"
done
ditto "$ROOT/assets" "$APP/Contents/Resources"
cp "$ROOT/assets/Google_Meet_icon_(2020).svg.png" "$APP/Contents/Resources/google-meet.png"
cp "$ROOT/assets/Microsoft_Office_Teams_(2025–present).svg.png" "$APP/Contents/Resources/teams.png"
cp "$ROOT/assets/Slack_icon_2019.svg.png" "$APP/Contents/Resources/slack.png"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<!-- Preserve the existing bundle identity for Keychain and macOS permission continuity. -->
<key>CFBundleIdentifier</key><string>ai.privategranola.local</string>
<key>CFBundleName</key><string>Hush</string>
<key>CFBundleExecutable</key><string>Hush</string>
<key>CFBundleDisplayName</key><string>Hush</string>
<key>MuesliSupportDirectoryName</key><string>PrivateGranola</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>LSMinimumSystemVersion</key><string>14.2</string>
<key>NSMicrophoneUsageDescription</key><string>Hush records your microphone for private meeting notes, with your consent.</string>
<key>NSAudioCaptureUsageDescription</key><string>Hush records meeting audio for private transcription, with participants’ consent.</string>
<key>NSScreenCaptureUsageDescription</key><string>Hush captures meeting audio for private notes.</string>
<key>NSCalendarsFullAccessUsageDescription</key><string>Hush shows your upcoming meetings on this Mac so you can start notes from them. Events are never uploaded.</string>
<key>NSContactsUsageDescription</key><string>Hush lets you choose meeting participants from Contacts. Contacts stay on this Mac.</string>
<key>NSInputMonitoringUsageDescription</key><string>Hush uses keyboard shortcuts for dictation and meeting recording.</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
codesign --force --deep --sign - "$APP"
rm -rf "$ROOT/dist/Hush.app"
mv "$APP" "$ROOT/dist/Hush.app"
printf '%s\n' "$ROOT/dist/Hush.app"
