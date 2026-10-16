#!/bin/zsh
# Created by Amirali Yazdani on 10/16/26.
set -euo pipefail
cd "${0:A:h}"

swift build -c release --product MultiPascalMac

BIN=".build/release/MultiPascalMac"
APP="Multi-Pascal Mac.app"
ICON_SOURCE="Sources/MultiPascalMac/Resources/AppIcon.png"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/MultiPascalMac"
cp "$ICON_SOURCE" "$APP/Contents/Resources/AppIconPreview.png"

# Build the complete macOS .icns family from the 1024px master image.
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
trap 'rm -rf "${ICONSET:h}"' EXIT
make_icon() {
  local file="$1" size="$2"
  sips -z "$size" "$size" "$ICON_SOURCE" --out "$ICONSET/$file" >/dev/null
}
make_icon icon_16x16.png 16
make_icon icon_16x16@2x.png 32
make_icon icon_32x32.png 32
make_icon icon_32x32@2x.png 64
make_icon icon_128x128.png 128
make_icon icon_128x128@2x.png 256
make_icon icon_256x256.png 256
make_icon icon_256x256@2x.png 512
make_icon icon_512x512.png 512
make_icon icon_512x512@2x.png 1024
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleDisplayName</key><string>Multi-Pascal Mac</string>
<key>CFBundleExecutable</key><string>MultiPascalMac</string>
<key>CFBundleIdentifier</key><string>org.multipascal.mac</string>
<key>CFBundleName</key><string>Multi-Pascal Mac</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>NSHumanReadableCopyright</key><string>Copyright © 2026 Amirali Yazdani</string>
<key>CFBundleVersion</key><string>1.1</string>
<key>CFBundleShortVersionString</key><string>1.1</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
<key>NSHighResolutionCapable</key><true/>
<key>CFBundleDocumentTypes</key><array>
<dict>
<key>CFBundleTypeName</key><string>Multi-Pascal Source</string>
<key>CFBundleTypeRole</key><string>Editor</string>
<key>LSItemContentTypes</key><array><string>org.multipascal.source</string></array>
</dict>
</array>
<key>UTExportedTypeDeclarations</key><array>
<dict>
<key>UTTypeIdentifier</key><string>org.multipascal.source</string>
<key>UTTypeDescription</key><string>Multi-Pascal source code</string>
<key>UTTypeConformsTo</key><array><string>public.source-code</string></array>
<key>UTTypeTagSpecification</key><dict><key>public.filename-extension</key><array><string>mpf</string></array></dict>
</dict>
</array>
</dict></plist>
PLIST

echo "Built app bundle with custom icon: $APP"
