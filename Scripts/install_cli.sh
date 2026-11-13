#!/bin/bash
# 安装 fcpplugin 命令行工具。
# 默认装到 ~/bin；可以指定 BIN_DIR=/usr/local/bin（需要写权限）。
set -euo pipefail

cd "$(dirname "$0")/.."

APP_BUNDLE="$HOME/Applications/FCP 插件管理.app"
SOURCE_BIN="$APP_BUNDLE/Contents/MacOS/FCPXPluginManager"
BIN_DIR="${BIN_DIR:-$HOME/bin}"
TARGET="$BIN_DIR/fcpplugin"

if [ ! -x "$SOURCE_BIN" ]; then
    echo "找不到 $SOURCE_BIN"
    echo "请先运行：./Scripts/build_app.sh"
    exit 1
fi

mkdir -p "$BIN_DIR"
rm -f "$TARGET"
cp "$SOURCE_BIN" "$TARGET"
chmod 755 "$TARGET"

echo "已安装到：$TARGET"
echo ""

case ":$PATH:" in
    *":$BIN_DIR:"*)
        echo "$BIN_DIR 已经在 PATH 里，可以直接运行："
        ;;
    *)
        echo "$BIN_DIR 不在 PATH 里。把下面一行加到 ~/.zshrc，然后重开终端："
        echo "  export PATH=\"$BIN_DIR:\$PATH\""
        echo ""
        echo "当前会话可以先用完整路径：$TARGET"
        ;;
esac

echo ""
echo "试试（一定要带 --cli，否则会启动图形界面）："
echo "  fcpplugin --cli --version"
echo "  fcpplugin --cli list --category transitions"
echo "  fcpplugin --cli list --json"
echo "  fcpplugin --cli scan-project --path \"<工程.fcpxml 或库.fcpbundle>\""
echo ""
echo "卸载：rm \"$TARGET\""
