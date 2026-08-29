#!/bin/bash
#
# Refuse an app that carries ad-hoc signed code.
#
# Xcode signs an embedded Sparkle.framework but leaves the helper tools inside
# it (Updater.app, Autoupdate and the XPC services) ad-hoc signed. Exporting the
# archive re-signs them. An app taken straight out of the .xcarchive still has
# them ad-hoc signed, and notarization rejects it, so this runs after the export
# to catch a regression before the submission does.
#
# codesign output is captured rather than piped to grep. Under `pipefail`, a
# `grep -q` that matches closes the pipe early, codesign dies of SIGPIPE, and
# the successful match reads as a failed one.

set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "Usage: $0 APP_PATH" >&2
    exit 64
fi

app_path="$1"
found_adhoc=0

while IFS= read -r executable; do
    description="$(codesign --display --verbose=2 "$executable" 2>&1 || true)"
    if [[ "$description" == *adhoc* ]]; then
        echo "error: ad-hoc signed code in the bundle: $executable" >&2
        found_adhoc=1
    fi
done < <(find "$app_path" -type f -perm -111)

if [[ "$found_adhoc" -ne 0 ]]; then
    echo "error: notarization would reject this app. Did the export step run?" >&2
    exit 1
fi

description="$(codesign --display --verbose=2 "$app_path" 2>&1 || true)"
if [[ "$description" != *"Authority=Developer ID Application"* ]]; then
    echo "error: $app_path is not signed with a Developer ID Application identity." >&2
    exit 1
fi

codesign --verify --deep --strict --verbose=2 "$app_path"
echo "Every executable in $app_path is Developer ID signed."
