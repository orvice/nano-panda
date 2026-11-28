#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

version="${NANOPANDA_VERSION:-0.1.0}"
app="$root/dist/NanoPanda.app"
dmg="$root/dist/NanoPanda-${version}.dmg"

if [[ ! -d "$app" ]]; then
    echo "missing $app; run scripts/bundle-app.sh first" >&2
    exit 1
fi

staging="$(mktemp -d "$root/dist/.dmg.XXXXXX")"
trap 'rm -rf "$staging"' EXIT

ditto "$app" "$staging/NanoPanda.app"
ln -s /Applications "$staging/Applications"

rm -f "$dmg"
hdiutil create -volname "Nano Panda" -srcfolder "$staging" -fs HFS+ -format UDZO -ov "$dmg"
hdiutil verify "$dmg"
printf '%s\n' "$dmg"
