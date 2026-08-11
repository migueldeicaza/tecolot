#!/bin/bash

set -euo pipefail

if [[ $# -lt 2 || $# -gt 3 ]]; then
    echo "Usage: $0 APP_PATH OUTPUT_DMG [VOLUME_NAME]" >&2
    exit 64
fi

app_path="$1"
output_path="$2"
volume_name="${3:-Tecolot}"

if [[ ! -d "$app_path" || "$app_path" != *.app ]]; then
    echo "The app path is not an application bundle: $app_path" >&2
    exit 66
fi

if [[ "$output_path" != *.dmg ]]; then
    echo "The output path must end in .dmg: $output_path" >&2
    exit 64
fi

output_directory="$(dirname "$output_path")"
mkdir -p "$output_directory"
output_directory="$(cd "$output_directory" && pwd)"
output_path="$output_directory/$(basename "$output_path")"

staging_directory="$(mktemp -d "$output_directory/tecolot-dmg.XXXXXX")"
cleanup() {
    rm -rf "$staging_directory"
}
trap cleanup EXIT

ditto "$app_path" "$staging_directory/$(basename "$app_path")"
ln -s /Applications "$staging_directory/Applications"

hdiutil create \
    -volname "$volume_name" \
    -srcfolder "$staging_directory" \
    -format UDZO \
    -ov \
    "$output_path"
