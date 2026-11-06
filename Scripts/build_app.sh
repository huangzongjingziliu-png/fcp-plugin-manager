#!/bin/bash
# 从 SwiftPM 的 release 产物生成可双击运行的 .app，输出到 dist/
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="FCP 插件管理"
BUNDLE_ID="com.huangzongjing.fcppluginmanager"
APP_VERSION="1.5.2"
BUILD_VERSION="${BUILD_VERSION:-$(date +%Y%m%d)}"
EXECUTABLE_NAME="FCPXPluginManager"

DIST_DIR="$PWD/dist"
# 在临时目录里组装 .app：dist/ 只留压缩包，避免外置盘上的 .app 被启动台收录成第二个图标
STAGE_DIR="$(mktemp -d /tmp/fcp-app.XXXXXX)"
APP_BUNDLE="$STAGE_DIR/$APP_NAME.app"
INSTALL_PATH="$HOME/Applications/$APP_NAME.app"
ZIP_PATH="$DIST_DIR/FCP插件管理-${APP_VERSION}.zip"
ICON_WORK_DIR="$(mktemp -d /tmp/fcp-icon.XXXXXX)"
trap 'rm -rf "$ICON_WORK_DIR" "$STAGE_DIR"' EXIT

command -v swift >/dev/null 2>&1 || { echo "错误：找不到 swift，请先安装 Xcode。"; exit 1; }

echo "==> 编译 release 版本"
# 外置盘多为 exFAT，SwiftPM 的默认 .build 目录会因文件锁/扩展属性失败，统一放到临时目录
SCRATCH_PATH="${SCRATCH_PATH:-/tmp/fcp-release-build}"
swift build -c release --scratch-path "$SCRATCH_PATH" --product "$EXECUTABLE_NAME"
BIN_DIR="$(swift build -c release --scratch-path "$SCRATCH_PATH" --show-bin-path)"
BIN_PATH="$BIN_DIR/$EXECUTABLE_NAME"
[ -x "$BIN_PATH" ] || { echo "错误：找不到 release 产物 $BIN_PATH"; exit 1; }

echo "==> 准备 .app 目录"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$BIN_PATH" "$APP_BUNDLE/Contents/MacOS/$EXECUTABLE_NAME"

echo "==> 生成图标"
ICONSET_DIR="$ICON_WORK_DIR/AppIcon.iconset"
mkdir -p "$ICONSET_DIR"
swift Scripts/make_icon.swift "$ICONSET_DIR"
iconutil -c icns "$ICONSET_DIR" -o "$APP_BUNDLE/Contents/Resources/AppIcon.icns"

echo "==> 写入 Info.plist"
cat > "$APP_BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key>
    <string>$EXECUTABLE_NAME</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$APP_VERSION</string>
    <key>CFBundleVersion</key>
    <string>$BUILD_VERSION</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.utilities</string>
    <key>NSHumanReadableCopyright</key>
    <string>本机离线工具，仅管理 Final Cut Pro 插件文件</string>
</dict>
</plist>
PLIST

# exFAT 不支持扩展属性，签名可能失败；失败不影响本机双击运行
if codesign --force --deep --sign - "$APP_BUNDLE" >/dev/null 2>&1; then
    echo "==> 已做本地签名（ad-hoc）"
else
    echo "==> 提示：当前磁盘（可能是 exFAT）不支持签名，已跳过；本机双击仍可打开"
fi

find "$APP_BUNDLE" -name '._*' -delete 2>/dev/null || true

echo "==> 安装到 ~/Applications"
mkdir -p "$HOME/Applications"
if pgrep -f "$INSTALL_PATH/Contents/MacOS/$EXECUTABLE_NAME" >/dev/null 2>&1; then
    echo "    检测到软件正在运行，先退出再覆盖"
    osascript -e "quit app \"$APP_NAME\"" >/dev/null 2>&1 || true
    sleep 2
    pkill -f "$INSTALL_PATH/Contents/MacOS/$EXECUTABLE_NAME" >/dev/null 2>&1 || true
fi
ditto "$APP_BUNDLE" "$INSTALL_PATH"

echo "==> 打包到 dist（不留 .app，避免启动台出现重复图标）"
mkdir -p "$DIST_DIR"
rm -f "$ZIP_PATH"
ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$ZIP_PATH"
# 清掉旧版本遗留的可执行包
rm -rf "$DIST_DIR/$APP_NAME.app"

echo ""
echo "已安装：$INSTALL_PATH"
echo "压缩包：$ZIP_PATH"
echo "版本：${APP_VERSION}（构建 ${BUILD_VERSION}）"
echo "首次打开如被系统拦截，右键 →「打开」。"
