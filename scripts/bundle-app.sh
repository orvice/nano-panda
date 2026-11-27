#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

swift build -c release "$@"
binary_directory="$(swift build -c release --show-bin-path "$@")"
destination="$root/dist/NanoPanda.app"
mkdir -p "$root/dist"
staging="$(mktemp -d "$root/dist/.bundle.XXXXXX")"
cleanup() {
    if [[ -d "$staging/previous.app" && ! -e "$destination" ]]; then
        mv "$staging/previous.app" "$destination"
    fi
    rm -rf "$staging"
}
trap cleanup EXIT

bundle="$staging/NanoPanda.app"
mkdir -p "$bundle/Contents/MacOS"
install -m 0755 "$binary_directory/NanoPanda" "$bundle/Contents/MacOS/NanoPanda"
cat > "$bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDisplayName</key><string>Nano Panda</string>
    <key>CFBundleName</key><string>Nano Panda</string>
    <key>CFBundleExecutable</key><string>NanoPanda</string>
    <key>CFBundleIdentifier</key><string>dev.orvice.nanopanda</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
plutil -lint "$bundle/Contents/Info.plist"
codesign --sign - "$bundle"
codesign --verify --strict "$bundle"
if [[ -e "$destination" ]]; then
    mv "$destination" "$staging/previous.app"
fi
mv "$bundle" "$destination"
printf '%s\n' "$destination"
