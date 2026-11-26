#!/bin/bash
# Notarizes a signed app or disk image with Apple and staples the ticket to it,
# so it opens without a warning, even offline.
#
#   ./scripts/notarize.sh build/ScreenBox.app
#   ./scripts/notarize.sh build/ScreenBox-1.4.0.dmg
#
# Needs an App Store Connect API key: APPLE_API_KEY (the .p8's text),
# APPLE_API_KEY_ID and APPLE_API_ISSUER.
set -euo pipefail

TARGET="$1"
: "${APPLE_API_KEY:?}" "${APPLE_API_KEY_ID:?}" "${APPLE_API_ISSUER:?}"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
KEY="$WORK/key.p8"
printf '%s\n' "$APPLE_API_KEY" > "$KEY"

# notarytool takes a zip, a DMG or a package; an app goes up zipped.
SUBMIT="$TARGET"
if [[ "$TARGET" == *.app ]]; then
  SUBMIT="$WORK/$(basename "$TARGET").zip"
  ditto -c -k --keepParent "$TARGET" "$SUBMIT"
fi

OUT=$(xcrun notarytool submit "$SUBMIT" --key "$KEY" --key-id "$APPLE_API_KEY_ID" --issuer "$APPLE_API_ISSUER" --wait --output-format json)
echo "$OUT"
STATUS=$(echo "$OUT" | /usr/bin/plutil -extract status raw -o - - 2>/dev/null || true)
if [ "$STATUS" != Accepted ]; then
  # Apple's log says which file and why (unsigned code, no hardened runtime, no timestamp…).
  ID=$(echo "$OUT" | /usr/bin/plutil -extract id raw -o - - 2>/dev/null || true)
  [ -n "$ID" ] && xcrun notarytool log "$ID" --key "$KEY" --key-id "$APPLE_API_KEY_ID" --issuer "$APPLE_API_ISSUER" >&2
  echo "notarization: ${STATUS:-failed}" >&2
  exit 1
fi

xcrun stapler staple "$TARGET"
echo "notarized and stapled $TARGET"
