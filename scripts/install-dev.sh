#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCHEME="${SCHEME:-PinSnap}"
CONFIG="${CONFIG:-Debug}"
IDENTITY="${CODE_SIGN_IDENTITY:-PinSnap Local Signing}"
DEST="${INSTALL_DEST:-/Applications/PinSnap.app}"

cd "$ROOT"

if ! security find-identity -v -p codesigning | grep -q "\"$IDENTITY\""; then
  echo "error: no valid codesigning identity named \"$IDENTITY\"." >&2
  echo "Import /tmp/pinsnap-local.p12 and trust the cert for Code Signing (Keychain Access → trust)." >&2
  exit 1
fi

xcodegen generate
xcodebuild \
  -scheme "$SCHEME" \
  -configuration "$CONFIG" \
  -destination 'platform=macOS' \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$IDENTITY" \
  build

BUILD_DIR="$(xcodebuild -scheme "$SCHEME" -configuration "$CONFIG" -destination 'platform=macOS' -showBuildSettings 2>/dev/null | awk -F ' = ' '/TARGET_BUILD_DIR/ {print $2; exit}')"
PRODUCT_NAME="$(xcodebuild -scheme "$SCHEME" -configuration "$CONFIG" -destination 'platform=macOS' -showBuildSettings 2>/dev/null | awk -F ' = ' '/FULL_PRODUCT_NAME/ {print $2; exit}')"
APP="$BUILD_DIR/$PRODUCT_NAME"

if [[ ! -d "$APP" ]]; then
  echo "error: built app not found at $APP" >&2
  exit 1
fi

rm -rf "$DEST"
ditto "$APP" "$DEST"
codesign -dvvv "$DEST" 2>&1 | grep -E 'Authority=|Identifier=' || true
echo "Installed $DEST (signed as-is, no ad-hoc re-sign)."
