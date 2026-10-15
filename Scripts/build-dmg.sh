#!/bin/bash
#
# Packages dist/BatteryScope.app into a distributable disk image.
#
# The image holds the app plus a symlink to /Applications, which is the layout people expect:
# mount it, drag the app across, eject. It is built in a staging directory rather than from `dist`
# so the DMG does not pick up `dist/batteryscope-cli` or any stray `.DS_Store`.
#
# Usage: Scripts/build-dmg.sh [output-directory]
#   default output directory: ~/Downloads

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/dist/BatteryScope.app"
OUTPUT_DIR="${1:-$HOME/Downloads}"

info() { printf '  %s\n' "$1"; }
fail() { printf '❌ %s\n' "$1" >&2; exit 1; }

[ -d "$APP" ] || fail "找不到 $APP，请先运行 make app"
[ -d "$OUTPUT_DIR" ] || fail "输出目录不存在：$OUTPUT_DIR"

# Version and bundle id come from the built app, so the file name can never drift from what is
# actually inside the image.
PLIST="$APP/Contents/Info.plist"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST" 2>/dev/null || echo "1.0.0")"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST" 2>/dev/null || echo "unknown")"
DMG_NAME="BatteryScope-$VERSION.dmg"
DMG_PATH="$OUTPUT_DIR/$DMG_NAME"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

echo "打包 BatteryScope $VERSION"
info "源应用    $APP"
info "Bundle ID $BUNDLE_ID"
info "输出      $DMG_PATH"

# ditto rather than cp: it preserves resource forks, extended attributes and the code signature.
ditto "$APP" "$STAGE/BatteryScope.app"
ln -s /Applications "$STAGE/Applications"

# A running copy would be captured mid-write, and its signature check would fail after mounting.
if pgrep -x BatteryScope >/dev/null 2>&1; then
    info "注意：BatteryScope 正在运行，镜像里是磁盘上的副本，不受影响"
fi

rm -f "$DMG_PATH"
# UDZO = zlib-compressed, read-only: the standard distribution format.
hdiutil create \
    -volname "BatteryScope" \
    -srcfolder "$STAGE" \
    -fs HFS+ \
    -format UDZO \
    -ov \
    -quiet \
    "$DMG_PATH" || fail "hdiutil 创建镜像失败"

# Ad-hoc signing survives the copy, but verify rather than assume.
info "验证签名…"
codesign --verify --deep --strict "$APP" 2>/dev/null \
    && info "签名有效（ad-hoc）" \
    || info "签名校验未通过（ad-hoc 签名在部分系统上会这样，本机自用无妨）"

info "校验镜像…"
hdiutil verify "$DMG_PATH" >/dev/null 2>&1 && info "镜像完整" || fail "镜像校验失败"

# Mount it once to confirm what a user would actually see. The mount point is supplied explicitly
# because parsing it out of `hdiutil attach` output is fragile (that silently failed the first time,
# leaving the check to report "could not mount" on a perfectly good image).
MOUNT_POINT="$(mktemp -d)"
if hdiutil attach "$DMG_PATH" -nobrowse -readonly -quiet -mountpoint "$MOUNT_POINT" 2>/dev/null; then
    info "挂载内容："
    for entry in "$MOUNT_POINT"/* "$MOUNT_POINT"/.[!.]*; do
        [ -e "$entry" ] || continue
        name="$(basename "$entry")"
        if [ -L "$entry" ]; then
            info "    $name -> $(readlink "$entry")"
        elif [ -d "$entry" ]; then
            info "    $name/  ($(du -sh "$entry" | cut -f1))"
        else
            info "    $name"
        fi
    done
    # The point of the image is a launchable app, so check that specifically.
    if [ -x "$MOUNT_POINT/BatteryScope.app/Contents/MacOS/BatteryScope" ]; then
        info "镜像内的可执行文件存在"
    else
        hdiutil detach "$MOUNT_POINT" -quiet 2>/dev/null || true
        fail "镜像内的可执行文件缺失"
    fi
    hdiutil detach "$MOUNT_POINT" -quiet || fail "无法卸载镜像"
    info "已卸载"
else
    fail "无法挂载镜像以自检"
fi
rmdir "$MOUNT_POINT" 2>/dev/null || true

SIZE="$(du -h "$DMG_PATH" | cut -f1)"
CHECKSUM="$(shasum -a 256 "$DMG_PATH" | cut -d' ' -f1)"
echo
echo "✅ 已生成 $DMG_PATH"
info "大小    $SIZE"
info "SHA-256 $CHECKSUM"
