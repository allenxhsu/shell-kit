#!/bin/sh
# Build "Pairing Sample.app" from the PairingSample target and Examples/sample-web.
#
#   scripts/build-sample-app.sh            # release build into build/
#   CONFIG=debug scripts/build-sample-app.sh
#
# The same shape as an app's own build script (SysML's macos/scripts/build-app.sh),
# kept here because pairing is the one part of the kit that cannot be proved by
# `swift test`: the callback comes back through Launch Services, which only
# talks to bundles. This script is also the worked example of registering the
# URL type — the two lines around url-types.mjs.
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
KIT="$(cd "$HERE/.." && pwd)"
CONFIG="${CONFIG:-release}"
OUT="${OUT_DIR:-$KIT/build}"
APP="$OUT/Pairing Sample.app"
SCHEME="sample"

# The page's vendored copy of host.js, exactly as an app keeps one.
node "$KIT/scripts/copy-into.mjs" "$KIT/Examples/sample-web/host.js" >/dev/null

swift build --package-path "$KIT" -c "$CONFIG" --product PairingSample
BIN_DIR="$(swift build --package-path "$KIT" -c "$CONFIG" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/web"
cp "$BIN_DIR/PairingSample" "$APP/Contents/MacOS/Pairing Sample"
cp "$KIT/Examples/sample-web/index.html" "$KIT/Examples/sample-web/app.js" \
   "$KIT/Examples/sample-web/host.js" "$APP/Contents/Resources/web/"

# Without this block the sheet opens, the person signs in, and the redirect
# goes nowhere: Launch Services delivers sample://connect only to a bundle
# that claims the scheme.
URL_TYPES="$(node "$KIT/scripts/url-types.mjs" "$SCHEME" "Pairing Sample")"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Pairing Sample</string>
  <key>CFBundleDisplayName</key><string>Pairing Sample</string>
  <key>CFBundleIdentifier</key><string>org.toolkit.shell-kit.pairing-sample</string>
  <key>CFBundleExecutable</key><string>Pairing Sample</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>Sample Note</string>
      <key>CFBundleTypeRole</key><string>Editor</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key><array><string>public.json</string></array>
      <key>NSDocumentClass</key><string>PairingSample.NoteDocument</string>
    </dict>
  </array>
$URL_TYPES
</dict>
</plist>
PLIST

# Say so now rather than after a person has signed in for nothing.
node "$KIT/scripts/url-types.mjs" --check "$APP/Contents/Info.plist" "$SCHEME"

codesign --force --sign - "$APP" >/dev/null
echo "$APP"
