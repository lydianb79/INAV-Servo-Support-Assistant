#!/bin/bash
# Builds "INAV Servo Support Assistant.app" from the Swift package in this folder.
# Requirements: macOS 13+, Xcode or the Xcode Command Line Tools (xcode-select --install).
#
#   ./build_app.sh            -> native release build
#   ./build_app.sh --universal -> arm64 + x86_64 (needs full Xcode)
#   ./build_app.sh --run       -> build and launch
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="INAV Servo Support Assistant"
EXE="INAVServoSupport"
BUNDLE_ID="local.inav.servo-support-assistant"
VERSION="1.0.0"

ARCH_FLAGS=()
RUN=0
for a in "$@"; do
  case "$a" in
    --universal) ARCH_FLAGS=(--arch arm64 --arch x86_64) ;;
    --run) RUN=1 ;;
  esac
done

if ! command -v swift >/dev/null 2>&1; then
  echo "error: 'swift' not found. Install Xcode or run: xcode-select --install" >&2
  exit 1
fi

echo "==> swift build (release)"
swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}
BIN_DIR="$(swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)"

APP="$APP_NAME.app"
echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$EXE" "$APP/Contents/MacOS/$EXE"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleExecutable</key><string>$EXE</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSDesktopFolderUsageDescription</key><string>Reads and edits inav target files you select.</string>
  <key>NSDocumentsFolderUsageDescription</key><string>Reads and edits inav target files you select.</string>
</dict>
</plist>
PLIST

# Optional icon: put a 1024x1024 AppIcon.png next to this script.
if [ -f AppIcon.png ] && command -v iconutil >/dev/null 2>&1; then
  ICONSET="$(mktemp -d)/AppIcon.iconset"
  mkdir -p "$ICONSET"
  for s in 16 32 128 256 512; do
    sips -z $s $s AppIcon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) AppIcon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
fi

echo "==> ad-hoc code signing"
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || echo "warning: codesign failed (app still runs locally)"

# macOS caches app icons per bundle path. Because the bundle is deleted and recreated here,
# Finder/Dock would keep showing the old (or generic) icon – touch the bundle and re-register it.
touch "$APP" "$APP/Contents/Info.plist"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
[ -x "$LSREGISTER" ] && "$LSREGISTER" -f "$APP" >/dev/null 2>&1 || true

echo "==> done: $(pwd)/$APP"
if [ "$RUN" = "1" ]; then open "$APP"; fi
