#!/bin/zsh
# 编译 MediaImporter 为通用二进制（Intel + Apple Silicon）的 .app
set -e
cd "$(dirname "$0")"

APP="MediaImporter.app"
BIN="$APP/Contents/MacOS/MediaImporter"
SOURCES=(MediaImporter/*.swift)
SDK="$(xcrun --show-sdk-path)"

# 预检：SwiftUI 宏（@State 等）依赖 SwiftUIMacros 插件，仅完整版 Xcode 工具链附带
if [[ "$(xcode-select -p)" == *CommandLineTools* ]]; then
  echo "错误：当前 xcode-select 指向 Command Line Tools，缺少 SwiftUI 宏插件（SwiftUIMacros）。"
  echo "      编译 SwiftUI 源码需安装完整版 Xcode 后执行："
  echo "      sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
  exit 1
fi

echo "==> 编译 arm64"
xcrun swiftc -parse-as-library -O "${SOURCES[@]}" -o /tmp/mi_arm64 -target arm64-apple-macos12.0 -sdk "$SDK"

echo "==> 编译 x86_64"
xcrun swiftc -parse-as-library -O "${SOURCES[@]}" -o /tmp/mi_x64 -target x86_64-apple-macos12.0 -sdk "$SDK"

echo "==> 合并为 Universal 2"
mkdir -p "$APP/Contents/MacOS"
lipo -create /tmp/mi_arm64 /tmp/mi_x64 -output /tmp/mi_universal
cp -f /tmp/mi_universal "$BIN"
chmod +x "$BIN"
rm -f /tmp/mi_arm64 /tmp/mi_x64 /tmp/mi_universal

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>MediaImporter</string>
    <key>CFBundleIdentifier</key>
    <string>com.local.MediaImporter</string>
    <key>CFBundleName</key>
    <string>MediaImporter</string>
    <key>CFBundleDisplayName</key>
    <string>媒体导入工具</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>12.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSCameraUsageDescription</key>
    <string>需要访问已连接的 iPhone / iPad 以导出照片和视频。</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
</dict>
</plist>
PLIST

mkdir -p "$APP/Contents/Resources"
[ -f AppIcon.icns ] && cp -f AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

touch "$APP"

echo "==> ad-hoc 签名（bundle 级，绑定 Info.plist 与资源）"
find "$APP" -name "*.cstemp" -delete 2>/dev/null || true
codesign --force --deep --sign - "$APP"
codesign --verify --strict "$APP"
echo "==> 签名校验通过"

echo "==> 生成分发 zip（ditto 保留权限位与符号链接，勿用 Finder 压缩替代）"
rm -f "${APP}.zip"
ditto -c -k --keepParent "$APP" "${APP}.zip"

echo "==> 完成：$PWD/$APP"
echo "==> 分发包：$PWD/${APP}.zip"
lipo -info "$BIN"
