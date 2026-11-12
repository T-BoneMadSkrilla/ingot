#!/bin/bash
# Builds Ingot.app: the SwiftUI library (Ingot) and, inside it, the player
# (Contents/Helpers/Ingot Player.app, the Metal build's xboxrun) it runs each
# game in.
#
#   mac/ingot/build.sh [out dir]      default: <repo>/../build
#
# The Metal core's build directory is configured once with
#   cmake -G Ninja -S mac -B ../build/mac-metal -DHAKUX_GPU=metal
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
src="$(cd "$here/../.." && pwd)"
out="${1:-$src/../build}"
core_build="${INGOT_CORE_BUILD:-$out/mac-metal}"
work="$out/ingot"
app="$out/Ingot.app"
version="1.0.1"

mkdir -p "$work"
if [ ! -f "$core_build/build.ninja" ]; then
  cmake -G Ninja -S "$src/mac" -B "$core_build" -DHAKUX_GPU=metal -DCMAKE_BUILD_TYPE=Release
fi
ninja -C "$core_build" xboxrun

swiftc -O -parse-as-library -target arm64-apple-macos14.4 "$here"/Sources/Ingot/*.swift -o "$work/Ingot"

if [ ! -f "$work/Ingot.icns" ] || [ "$here/make_icon.swift" -nt "$work/Ingot.icns" ] ||
   [ "$here/icon.png" -nt "$work/Ingot.icns" ]; then
  swiftc -O "$here/make_icon.swift" -o "$work/make_icon"
  "$work/make_icon" "$here/icon.png" "$work/Ingot.png"
  rm -rf "$work/Ingot.iconset"
  mkdir "$work/Ingot.iconset"
  for s in 16 32 128 256 512; do
    sips -z $s $s "$work/Ingot.png" --out "$work/Ingot.iconset/icon_${s}x${s}.png" >/dev/null
    sips -z $((s * 2)) $((s * 2)) "$work/Ingot.png" --out "$work/Ingot.iconset/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$work/Ingot.iconset" -o "$work/Ingot.icns"
fi

plist() { # name, executable, identifier, extra keys
  cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$1</string>
  <key>CFBundleDisplayName</key><string>$1</string>
  <key>CFBundleExecutable</key><string>$2</string>
  <key>CFBundleIdentifier</key><string>$3</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>Ingot</string>
  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>CFBundleVersion</key><string>$version</string>
  <key>LSMinimumSystemVersion</key><string>14.4</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.games</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>Free software under the GNU GPL v3 or later. Based on hakuX.</string>
  $4
</dict>
</plist>
EOF
}

rm -rf "$app"
player="$app/Contents/Helpers/Ingot Player.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$player/Contents/MacOS" "$player/Contents/Resources"
cp "$work/Ingot" "$app/Contents/MacOS/Ingot"
cp "$work/Ingot.icns" "$app/Contents/Resources/"
plist Ingot Ingot app.ingot.Ingot "<key>CFBundleDocumentTypes</key><array><dict>
    <key>CFBundleTypeName</key><string>Xbox Disc Image</string>
    <key>CFBundleTypeRole</key><string>Viewer</string>
    <key>LSHandlerRank</key><string>Alternate</string>
    <key>LSItemContentTypes</key><array><string>public.iso-image</string></array>
    <key>CFBundleTypeExtensions</key><array><string>iso</string><string>xiso</string></array>
  </dict></array>" > "$app/Contents/Info.plist"
cp "$core_build/native/xboxrun" "$player/Contents/MacOS/Ingot Player"
cp "$work/Ingot.icns" "$player/Contents/Resources/"
plist Ingot "Ingot Player" app.ingot.Ingot.Player \
  "<key>NSMicrophoneUsageDescription</key><string>Games that use the Xbox headset.</string>" \
  > "$player/Contents/Info.plist"
cp "$src/COPYING" "$app/Contents/Resources/COPYING.txt"

codesign --force --sign - "$player"
codesign --force --sign - "$app"
echo "built $app"
