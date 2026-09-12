#!/bin/bash
# 一键构建：编译两个 Swift 工具 → 生成应用图标 → 组装 "DSH Web.app"。
#
# 只改 launch-dsh-web.sh / dsh-tray.swift 的逻辑时，不必跑本脚本也能生效：
#   - launch-dsh-web.sh 是薄壳 .app 每次点击现读现跑的脚本；
#   - dsh-tray.swift 改完需要重新 `swiftc` 编译（本脚本会做）。
# 改了 Info.plist / 图标 / 需要重新编译时，跑一次本脚本即可。
set -eu

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"
APP="$HERE/DSH Web.app"

# Swift 编译要写模块缓存，默认落在 ~/Library；指到本目录，避免污染用户目录
export CLANG_MODULE_CACHE_PATH="$HERE/.module-cache"
export SWIFT_MODULE_CACHE_PATH="$HERE/.module-cache"
mkdir -p "$HERE/.module-cache"

if ! command -v swiftc >/dev/null 2>&1; then
  echo "找不到 swiftc。装 Xcode 命令行工具：xcode-select --install" >&2
  exit 1
fi

echo "==> 编译 screen-bounds（取屏幕可用区域）"
swiftc -O -o screen-bounds screen-bounds.swift

echo "==> 编译 dsh-tray（菜单栏图标）"
swiftc -O -o dsh-tray dsh-tray.swift

if [ -f "$HERE/icons/app-icon-mac.png" ]; then
  echo "==> 生成应用图标 AppIcon.icns"
  rm -rf AppIcon.iconset
  mkdir AppIcon.iconset
  for s in 16 32 128 256 512; do
    sips -z "$s" "$s" icons/app-icon-mac.png --out "AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
    d=$((s * 2))
    sips -z "$d" "$d" icons/app-icon-mac.png --out "AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns AppIcon.iconset -o AppIcon.icns
fi

echo "==> 组装 DSH Web.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$HERE/Info.plist" "$APP/Contents/Info.plist"
cat >"$APP/Contents/MacOS/launch" <<EOF
#!/bin/bash
# 薄包装：真正的逻辑在 dsh-launcher/launch-dsh-web.sh，改它无需重建 .app
exec "$HERE/launch-dsh-web.sh"
EOF
chmod +x "$APP/Contents/MacOS/launch" "$HERE/launch-dsh-web.sh"

if [ -f "$HERE/AppIcon.icns" ]; then
  cp "$HERE/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
  echo "    已附带图标 AppIcon.icns"
fi

# 让 Finder/Dock 立刻感知 bundle 变化
touch "$APP"
plutil -lint "$APP/Contents/Info.plist" >/dev/null

echo "==> 完成：$APP"
echo "    装到应用目录：cp -R \"$APP\" /Applications/"
