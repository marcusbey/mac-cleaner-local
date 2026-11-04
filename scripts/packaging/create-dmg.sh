#!/bin/bash
set -euo pipefail
if [[ $# -ne 3 ]]; then echo 'Usage: create-dmg.sh app-path output-dmg volume-name' >&2; exit 2; fi
app_path="$1"
output_dmg="$2"
volume_name="$3"
[[ -d "$app_path/Contents" ]] || { echo 'App bundle missing' >&2; exit 1; }
[[ ! -e "$output_dmg" ]] || { echo 'Refusing to overwrite existing DMG' >&2; exit 1; }
stage_dir="$(mktemp -d /tmp/app-cleaner-dmg.XXXXXX)"
trap 'if [[ -d "$stage_dir" && "$stage_dir" == /tmp/app-cleaner-dmg.* ]]; then /bin/rm -r "$stage_dir"; fi' EXIT
/usr/bin/ditto "$app_path" "$stage_dir/$(basename "$app_path")"
ln -s /Applications "$stage_dir/Applications"
cat > "$stage_dir/Install.txt" <<'TEXT'
App Cleaner — macOS 14 or later

1. Drag the app into Applications.
2. Eject this disk image.
3. Open the app from Applications.

The Electron edition includes a native macOS companion inside its app bundle.
Click Open App Cleaner to launch the native tools and memory menu-bar icon.
No Node.js, npm, Swift, or Xcode installation is needed.

This personal build is ad-hoc signed, not Developer ID signed or notarized.
macOS may block its first launch. Review it using System Settings > Privacy & Security.
Do not disable Gatekeeper or run unknown commands to bypass system security.

Settings and permissions are local to each Mac. Free up memory asks for your
administrator password; turning on Automatically free up asks once to allow
password-free cleaning on that Mac. Space Map may ask to access protected
folders; grant Full Disk Access in System Settings to measure everything.
TEXT
mkdir -p "$(dirname "$output_dmg")"
hdiutil create -volname "$volume_name" -srcfolder "$stage_dir" -format UDZO -ov "$output_dmg"
hdiutil verify "$output_dmg"
