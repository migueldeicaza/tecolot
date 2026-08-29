#!/bin/bash
#
# Submit a file to the Apple notary service, then staple the ticket.
#
# notarytool exits successfully even when it reports a status of Invalid, so a
# workflow that does not check the status fails later at stapler with an error
# that says nothing about the real cause. This checks the status and prints
# Apple's own log, which names the offending binary.

set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo "Usage: $0 SUBMIT_PATH STAPLE_PATH" >&2
    echo "A ticket cannot be stapled to a ZIP, so the app inside it is the" >&2
    echo "staple target while the ZIP is what gets submitted." >&2
    exit 64
fi

submit_path="$1"
staple_path="$2"

: "${NOTARY_KEY_PATH:?NOTARY_KEY_PATH is not set}"
: "${NOTARY_KEY_ID:?NOTARY_KEY_ID is not set}"
: "${NOTARY_ISSUER_ID:?NOTARY_ISSUER_ID is not set}"

submission="$(xcrun notarytool submit "$submit_path" \
    --key "$NOTARY_KEY_PATH" \
    --key-id "$NOTARY_KEY_ID" \
    --issuer "$NOTARY_ISSUER_ID" \
    --wait \
    --output-format json)"

read_field() {
    printf '%s' "$submission" | /usr/bin/python3 -c \
        "import json, sys; print(json.load(sys.stdin).get('$1', ''))"
}

submission_id="$(read_field id)"
status="$(read_field status)"

if [[ "$status" != "Accepted" ]]; then
    echo "error: notarization of $submit_path finished as '$status'." >&2
    echo "Apple's log follows." >&2
    xcrun notarytool log "$submission_id" \
        --key "$NOTARY_KEY_PATH" \
        --key-id "$NOTARY_KEY_ID" \
        --issuer "$NOTARY_ISSUER_ID" >&2 || true
    exit 1
fi

xcrun stapler staple "$staple_path"
xcrun stapler validate "$staple_path"
