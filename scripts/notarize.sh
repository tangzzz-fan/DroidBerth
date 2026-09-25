#!/bin/bash
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/env.sh"

APP="${1:-$APP_PATH}"

if ! require_developer_id; then
  echo
  echo "Generate a 'Developer ID Application' certificate in the Apple Developer portal,"
  echo "install it in the login keychain, then re-run scripts/build.sh."
  exit 2
fi

if [ -z "${NOTARY_PROFILE:-}" ]; then
  if [ -z "${APPLE_ID:-}" ] || [ -z "${APPLE_PASSWORD:-}" ] || [ -z "${APPLE_TEAM_ID:-}" ]; then
    cat >&2 <<'EOF'
Missing notarization credentials. Either store a keychain profile:

  scripts/wizard-developer-id.sh

  ...or export all three of:
    APPLE_ID        your@email.com
    APPLE_PASSWORD  an app-specific password
    APPLE_TEAM_ID   10-character team identifier
EOF
    exit 2
  fi
fi

if [ ! -d "$APP" ]; then
  echo "no app bundle at $APP" >&2
  exit 1
fi

submit() {
  local artifact="$1"
  if [ -n "${NOTARY_PROFILE:-}" ]; then
    xcrun notarytool submit "$artifact" --keychain-profile "$NOTARY_PROFILE" --wait
  else
    xcrun notarytool submit "$artifact" \
      --apple-id "$APPLE_ID" --password "$APPLE_PASSWORD" --team-id "$APPLE_TEAM_ID" --wait
  fi
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "==> 1/5 zip the app and notarize it"
ditto -c -k --keepParent "$APP" "$WORK/$APP_NAME.zip"
submit "$WORK/$APP_NAME.zip"

echo
echo "==> 2/5 staple the app"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

echo
echo "==> 3/5 build and sign the distribution DMG"
mkdir -p "$DMG_DIR"
DMG_OUT="$DMG_DIR/$APP_NAME.dmg"
make_signed_dmg "$APP" "$DMG_OUT"
echo "    $DMG_OUT"

echo
echo "==> 4/5 notarize the DMG"
submit "$DMG_OUT"

echo
echo "==> 5/5 staple the DMG"
xcrun stapler staple "$DMG_OUT"
xcrun stapler validate "$DMG_OUT"

echo
echo "notarization complete."
echo "now verify on a clean machine: scripts/verify-clean.sh \"$DMG_OUT\""
