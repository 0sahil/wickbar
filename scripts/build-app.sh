#!/usr/bin/env bash
# Builds a release Wickbar.app into build/.
#   scripts/build-app.sh            -> build/Wickbar.app
#   scripts/build-app.sh --install  -> also copies it to /Applications/Wickbar.app
# Signing: ad-hoc by default. Set SIGN_IDENTITY (e.g. "Developer ID Application: Name (TEAMID)")
# to sign with hardened runtime + secure timestamp, as required for notarization.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

INSTALL=0
for arg in "$@"; do
  case "$arg" in
    --install) INSTALL=1 ;;
    -h|--help) sed -n '2,6p' "$0"; exit 0 ;;
    *) echo "Unknown option: $arg" >&2; exit 2 ;;
  esac
done

APP_NAME="Wickbar"
BUNDLE_ID="com.0sahil.wickbar"
VERSION="$(tr -d '[:space:]' < VERSION)"
BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/$APP_NAME.app"
ICONSET="$BUILD_DIR/AppIcon.iconset"

echo "==> Building $APP_NAME $VERSION (release)"
swift build -c release --product "$APP_NAME"
BIN_DIR="$(swift build -c release --show-bin-path)"

echo "==> Assembling $APP"
rm -rf "$APP" "$ICONSET"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"

# Sparkle (in-app updates). SwiftPM links it as @rpath/Sparkle.framework but only adds build-tree rpaths.
echo "==> Embedding Sparkle.framework"
mkdir -p "$APP/Contents/Frameworks"
ditto "$BIN_DIR/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
# The XPC services are only needed by sandboxed apps; Sparkle's docs allow removing them otherwise.
rm -rf "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices" \
       "$APP/Contents/Frameworks/Sparkle.framework/XPCServices"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/$APP_NAME"

# SwiftPM resource bundles (none today, but copy any that appear).
shopt -s nullglob
for bundle in "$BIN_DIR"/*.bundle; do
  cp -R "$bundle" "$APP/Contents/Resources/"
done
shopt -u nullglob

echo "==> Generating icon"
mkdir -p "$BUILD_DIR/tools"
swiftc -O -o "$BUILD_DIR/tools/make-icon" "$ROOT/scripts/make-icon.swift"
"$BUILD_DIR/tools/make-icon" "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

BUILD_NUMBER="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)"
# Sparkle: the appcast is a release asset, so it is only served once a draft release is published.
# SUEnableAutomaticChecks skips Sparkle's "check automatically?" prompt; the Settings toggle turns it off.
FEED_URL="https://github.com/0sahil/wickbar/releases/latest/download/appcast.xml"
SPARKLE_PUBLIC_KEY="CjTyR0tSh2gi26TITWkJr+Idwr6xW6Nv7kUuR9EdHII="
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticTermination</key><false/>
  <key>NSSupportsSuddenTermination</key><false/>
  <key>NSHumanReadableCopyright</key><string>© 2026 Sahil. MIT License.</string>
  <key>SUFeedURL</key><string>$FEED_URL</string>
  <key>SUPublicEDKey</key><string>$SPARKLE_PUBLIC_KEY</string>
  <key>SUEnableAutomaticChecks</key><true/>
</dict>
</plist>
PLIST
printf 'APPL????' > "$APP/Contents/PkgInfo"
plutil -lint "$APP/Contents/Info.plist" >/dev/null

# Inside-out, without --deep (per Sparkle's docs): Sparkle's helpers, then the framework, then the app.
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
NESTED=("$SPARKLE/Versions/B/Autoupdate" "$SPARKLE/Versions/B/Updater.app" "$SPARKLE")
if [[ -n "${SIGN_IDENTITY:-}" ]]; then
  echo "==> Signing with: $SIGN_IDENTITY (hardened runtime)"
  for item in "${NESTED[@]}"; do
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$item"
  done
  codesign --force --options runtime --timestamp \
    --entitlements "$ROOT/scripts/Wickbar.entitlements" \
    --sign "$SIGN_IDENTITY" "$APP"
else
  echo "==> Signing (ad-hoc)"
  for item in "${NESTED[@]}"; do
    codesign --force --sign - --timestamp=none "$item"
  done
  codesign --force --sign - --timestamp=none "$APP"
fi
codesign --verify --deep --strict --verbose=2 "$APP"

echo "==> Built $APP"

if [[ "$INSTALL" == "1" ]]; then
  DEST="/Applications/$APP_NAME.app"
  if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
    echo "==> $APP_NAME is running; quitting it first"
    osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
    for _ in $(seq 1 40); do pgrep -x "$APP_NAME" >/dev/null 2>&1 || break; sleep 0.25; done
  fi
  echo "==> Installing to $DEST"
  rm -rf "$DEST"
  cp -R "$APP" "$DEST"
  echo "==> Installed. Launch with: open \"$DEST\""
fi
