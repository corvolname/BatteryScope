#!/bin/bash
# Builds BatteryScope and assembles a double-clickable .app bundle.
#
#   dist/BatteryScope.app      the menu bar app
#   dist/batteryscope-cli      the command line reader / self-test tool
#
# Usage: Scripts/build-app.sh [debug|release]     (default: release)
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT=$(pwd)

CONFIG="${1:-release}"
APP_NAME="BatteryScope"
CLI_NAME="batteryscope-cli"
VERSION="1.0.0"
BUILD_NUMBER="1"
MINIMUM_SYSTEM="14.0"

# --- SDK selection ----------------------------------------------------------------------
# A bare `swift build` would use the default SDK, whose SwiftUI declares @State as a macro
# from a plugin that only Xcode ships. See Scripts/resolve-sdk.sh for the full explanation.
SDK="$("$ROOT/Scripts/resolve-sdk.sh")"
export SDKROOT="$SDK"
echo "==> 使用 SDK: $SDK"

# --- Compile ---------------------------------------------------------------------------
echo "==> 编译（${CONFIG}）"
swift build -c "$CONFIG" --product "$APP_NAME"
swift build -c "$CONFIG" --product "$CLI_NAME"
BIN_DIR=$(swift build -c "$CONFIG" --show-bin-path)

# --- Self-test: fail the packaging rather than ship a broken build ---------------------
echo "==> 自检"
"$BIN_DIR/$CLI_NAME" selftest

# --- Bundle layout ---------------------------------------------------------------------
DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"
echo "==> 组装 $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN_DIR/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
printf 'APPL????' > "$APP/Contents/PkgInfo"

sed -e "s/@VERSION@/$VERSION/" \
    -e "s/@BUILD@/$BUILD_NUMBER/" \
    -e "s/@MINIMUM_SYSTEM@/$MINIMUM_SYSTEM/" \
    "$ROOT/Scripts/Info.plist.template" > "$APP/Contents/Info.plist"

# --- Icon ------------------------------------------------------------------------------
echo "==> 生成图标"
ICONSET_DIR="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET_DIR"
"$BIN_DIR/$CLI_NAME" export-icon --out "$ICONSET_DIR" > /dev/null
iconutil -c icns "$ICONSET_DIR" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$(dirname "$ICONSET_DIR")"

# --- Command line tool alongside the app ----------------------------------------------
cp "$BIN_DIR/$CLI_NAME" "$DIST/$CLI_NAME"

# --- Sign (ad-hoc) --------------------------------------------------------------------
# Ad-hoc signing is enough for a locally built app. It also keeps macOS from re-prompting for
# permissions on every rebuild, because the signature is at least stable per binary.
echo "==> 临时签名"
codesign --force --sign - "$DIST/$CLI_NAME" >/dev/null 2>&1 || true
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
codesign --verify --deep --strict "$APP" 2>/dev/null && echo "    签名校验通过" || echo "    (签名校验跳过)"

echo
echo "完成："
echo "  应用   $APP"
echo "  命令行 $DIST/$CLI_NAME"
echo
echo "启动： open \"$APP\""
