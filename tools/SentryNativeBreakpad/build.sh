#!/usr/bin/env bash
set -euo pipefail

package_dir="$(cd "$(dirname "$0")" && pwd)"
work_dir="$package_dir/.build-native"
source_dir="$work_dir/sentry-native"
cmake_dir="$work_dir/cmake"
sdk_version=0.17.6
sdk_commit=7afc37457d7fcc37fb0bace9c8045d3fa687717f

if [[ ! -d "$source_dir/.git" ]]; then
    mkdir -p "$work_dir"
    git clone --branch "$sdk_version" --depth 1 \
        https://github.com/getsentry/sentry-native.git "$source_dir"
fi

# An existing clone can be at an earlier pinned version. Move it to the
# pinned tag instead of stopping.
if [[ "$(git -C "$source_dir" rev-parse HEAD)" != "$sdk_commit" ]]; then
    git -C "$source_dir" fetch --depth 1 origin "refs/tags/$sdk_version:refs/tags/$sdk_version"
    git -C "$source_dir" checkout --detach "$sdk_version"
    # The old CMake cache can refer to files of the earlier version.
    rm -rf "$cmake_dir"
fi

if [[ "$(git -C "$source_dir" rev-parse HEAD)" != "$sdk_commit" ]]; then
    echo "The tag $sdk_version is not at the pinned commit $sdk_commit." >&2
    exit 1
fi

git -C "$source_dir" submodule update --init external/breakpad

sdk_root="$(xcrun --sdk macosx --show-sdk-path)"
cmake -S "$source_dir" -B "$cmake_dir" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=15.5 \
    '-DCMAKE_OSX_ARCHITECTURES=arm64;x86_64' \
    -DCMAKE_OSX_SYSROOT="$sdk_root" \
    -DSENTRY_BACKEND=breakpad \
    -DSENTRY_TRANSPORT=none \
    -DSENTRY_BUILD_SHARED_LIBS=OFF \
    -DSENTRY_BUILD_TESTS=OFF \
    -DSENTRY_BUILD_EXAMPLES=OFF \
    -DSENTRY_ENABLE_INSTALL=OFF
cmake --build "$cmake_dir" --parallel

headers_dir="$work_dir/Headers"
mkdir -p "$headers_dir"
cp "$source_dir/include/sentry.h" "$headers_dir/sentry.h"
cat > "$headers_dir/CSentryNative.h" <<'EOF'
#define SENTRY_BUILD_STATIC 1
#include "sentry.h"
EOF
cat > "$headers_dir/module.modulemap" <<'EOF'
module CSentryNative {
    header "CSentryNative.h"
    export *
}
EOF

combined_library="$work_dir/libCSentryNative.a"
xcrun libtool -static -o "$combined_library" \
    "$cmake_dir/libsentry.a" \
    "$cmake_dir/external/libbreakpad_client.a"

artifact_dir="$package_dir/Artifacts"
mkdir -p "$artifact_dir"
new_artifact="$work_dir/CSentryNative.xcframework"
rm -rf "$new_artifact"
xcodebuild -create-xcframework \
    -library "$combined_library" \
    -headers "$headers_dir" \
    -output "$new_artifact"
archs="$(xcrun lipo -archs "$new_artifact/macos-arm64_x86_64/libCSentryNative.a")"
if [[ " $archs " != *" arm64 "* || " $archs " != *" x86_64 "* ]]; then
    echo "The XCFramework needs arm64 and x86_64. Found: $archs" >&2
    exit 1
fi
rm -rf "$artifact_dir/CSentryNative.xcframework"
mv "$new_artifact" "$artifact_dir/CSentryNative.xcframework"

mkdir -p "$package_dir/Licenses"
cp "$source_dir/LICENSE" "$package_dir/Licenses/Sentry-Native-LICENSE"
cp "$source_dir/external/breakpad/LICENSE" "$package_dir/Licenses/Breakpad-LICENSE"

echo "Built $artifact_dir/CSentryNative.xcframework"
