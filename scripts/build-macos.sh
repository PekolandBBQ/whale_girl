#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [[ "$(uname -s)" != Darwin ]]; then echo 'Build on macOS with Xcode Command Line Tools.' >&2; exit 1; fi
case "$(uname -m)" in
  arm64) ARCH=arm64 ;;
  x86_64) ARCH=x64 ;;
  *) echo 'Unsupported architecture' >&2; exit 1 ;;
esac
VERSION=24.22.2
NAME="node-v$VERSION-darwin-$ARCH"
CACHE="$ROOT/artifacts/macos-cache"
mkdir -p "$CACHE" "$ROOT/dist"
if [[ ! -f "$CACHE/$NAME.tar.gz" ]]; then
  curl --fail --location --retry 3 "https://nodejs.org/dist/v$VERSION/$NAME.tar.gz" -o "$CACHE/$NAME.tar.gz"
fi
curl --fail --location --retry 3 "https://nodejs.org/dist/v$VERSION/SHASUMS256.txt" -o "$CACHE/SHASUMS256.txt"
(cd "$CACHE" && awk -v name="$NAME.tar.gz" '$2 == name {print}' SHASUMS256.txt > selected.sha256
 test -s selected.sha256
 shasum -a 256 -c selected.sha256
 tar -xzf "$NAME.tar.gz")
APP="$ROOT/dist/WhaleGirl-$ARCH.app"
if [[ -e "$APP" ]]; then echo "Output exists: $APP. Move it aside before rebuilding." >&2; exit 1; fi
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/app/macos" "$APP/Contents/Resources/app/scripts" "$APP/Contents/Resources/node/bin"
cp "$CACHE/$NAME/bin/node" "$APP/Contents/Resources/node/bin/node"
cp "$CACHE/$NAME/LICENSE" "$APP/Contents/Resources/node/LICENSE"
for entry in src assets server.js package.json config.example.json LICENSE NOTICE.md PRIVACY.md; do
  cp -R "$ROOT/$entry" "$APP/Contents/Resources/app/$entry"
done
for entry in host.js bridge.js wechat_adapter.py bridge-requirements.txt; do
  cp "$ROOT/macos/$entry" "$APP/Contents/Resources/app/macos/$entry"
done
cp "$ROOT/scripts/setup-macos-bridge.sh" "$APP/Contents/Resources/app/scripts/"
APP_VERSION="$("$CACHE/$NAME/bin/node" -p 'require(process.argv[1]).version' "$ROOT/package.json")"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>org.whalegirl.launcher</string>
<key>CFBundleName</key><string>鲸鲸</string>
<key>CFBundleExecutable</key><string>WhaleLauncher</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$APP_VERSION</string>
<key>CFBundleVersion</key><string>$APP_VERSION</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
swiftc -swift-version 5 -O -parse-as-library -target "$(uname -m)-apple-macosx14.0" \
  "$ROOT/macos/WhaleLauncher.swift" -o "$APP/Contents/MacOS/WhaleLauncher" -framework SwiftUI -framework AppKit
codesign --force --sign - "$APP/Contents/Resources/node/bin/node"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
ditto -c -k --keepParent "$APP" "$ROOT/dist/WhaleGirl-macos-$ARCH.zip"
echo "Built $APP (ad-hoc signed; not notarized)"
