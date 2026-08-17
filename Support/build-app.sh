#!/bin/zsh
# Build Vetro.app from the SwiftPM executable + Ghostty resources.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
GHOSTTY_SRC="${GHOSTTY_SRC:-../ghostty-src}"

# CLT lacks the SwiftUI macros plugin; borrow Xcode-beta's (matches SDK 27).
VETRO_DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}"
export DEVELOPER_DIR="$VETRO_DEVELOPER_DIR"
PLUGINS="$VETRO_DEVELOPER_DIR/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins"

# Keep compiler caches writable in restricted build environments.
VETRO_MODULE_CACHE="$(pwd)/.build/vetro-module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-$VETRO_MODULE_CACHE/swiftpm}"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$VETRO_MODULE_CACHE/clang}"
mkdir -p "$SWIFTPM_MODULECACHE_OVERRIDE" "$CLANG_MODULE_CACHE_PATH"

BUILD_ARGS=(--disable-sandbox -c "$CONFIG")
# The app bundle does not ship a dSYM; omit it for release packaging.
if [[ "$CONFIG" == "release" ]]; then
  BUILD_ARGS+=(-debug-info-format none)
fi
swift build "${BUILD_ARGS[@]}" -Xswiftc -plugin-path -Xswiftc "$PLUGINS"

BIN=".build/$CONFIG/Vetro"
APP="build/Vetro.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Support/Info.plist "$APP/Contents/Info.plist"
cp Support/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp "$BIN" "$APP/Contents/MacOS/Vetro"

# SwiftPM's processed VMKit guest assets are loaded through Bundle.module.
VMKIT_BUNDLE=".build/$CONFIG/Vetro_VMKit.bundle"
cp -R "$VMKIT_BUNDLE" "$APP/Contents/Resources/"

# Ghostty runtime resources: terminfo (xterm-ghostty), shell integration, themes.
if [ -d "$GHOSTTY_SRC/zig-out/share" ]; then
  mkdir -p "$APP/Contents/Resources/ghostty"
  cp -R "$GHOSTTY_SRC/zig-out/share/terminfo" "$APP/Contents/Resources/terminfo"
  cp -R "$GHOSTTY_SRC/zig-out/share/ghostty/". "$APP/Contents/Resources/ghostty/"
fi

# Prefer a real signing identity so the application keeps a stable system identity.
IDENTITY="${VETRO_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/{print $2; exit}')}"
codesign --force --sign "${IDENTITY:--}" --entitlements Support/Vetro.entitlements "$APP"
echo "Built $APP (signed: ${IDENTITY:-ad-hoc})"
