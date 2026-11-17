#!/usr/bin/env bash
set -euo pipefail

package_dir="$(cd "$(dirname "$0")" && pwd)"
artifact_dir="$package_dir/Artifacts"
xcframework="$artifact_dir/CSentryNative.xcframework"
archive="$artifact_dir/CSentryNative-0.17.6-macos.xcframework.zip"

if [[ ! -f "$xcframework/Info.plist" ]]; then
    echo "Build the XCFramework with 'make sentry-native' first." >&2
    exit 1
fi

rm -f "$archive"
ditto -c -k --keepParent --norsrc --noextattr "$xcframework" "$archive"
checksum="$(swift package compute-checksum "$archive")"
printf '%s\n' "$checksum" > "$archive.sha256"

echo "Archive: $archive"
echo "SwiftPM checksum: $checksum"
