#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
swift build -c release --arch arm64 --arch x86_64
binary=".build/out/Products/Release/AppCleaner"
if [[ ! -f "$binary" ]]; then binary=".build/apple/Products/Release/AppCleaner"; fi
lipo "$binary" -verify_arch arm64 x86_64
app_path="dist/universal/App Cleaner Local.app"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
[[ -f 'dist/App Cleaner Local.app/Contents/Info.plist' ]] || ./scripts/build-app.sh
cp 'dist/App Cleaner Local.app/Contents/Info.plist' "$app_path/Contents/Info.plist"
cp "$binary" "$app_path/Contents/MacOS/AppCleaner"
/usr/libexec/PlistBuddy -c 'Set :CFBundleShortVersionString 0.4.2' "$app_path/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleVersion 6' "$app_path/Contents/Info.plist"
codesign --force --sign - "$app_path"
codesign --verify --deep --strict "$app_path"
