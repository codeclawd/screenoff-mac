#!/bin/zsh
# Builds build/ScreenOff.app as a universal (Apple silicon + Intel) app, ad-hoc signed.
set -euo pipefail
cd "$(dirname "$0")"
APP="build/ScreenOff.app"
rm -rf "$APP" build/obj
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/obj
for arch in arm64 x86_64; do
  xcrun swiftc -O -target $arch-apple-macos14 Sources/*.swift -o build/obj/ScreenOff-$arch
done
lipo -create build/obj/ScreenOff-arm64 build/obj/ScreenOff-x86_64 -output "$APP/Contents/MacOS/ScreenOff"
cp Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP"
echo "Built $APP"
