#!/usr/bin/env bash
# Build Release PinSnap.app and pack a styled drag-install DMG into dist/.
#
# Learnings from common create-dmg tutorials:
# - Prefer create-dmg over hand-rolled Finder AppleScript
# - Background must be @2x pixels with DPI 144 (else Finder shrinks/crops it)
# - Do not bake app/Applications icons into the background — only guides (arrow)
# - Use --app-drop-link / --hide-extension / --volicon
#
# SKIP_BUILD=1 ./scripts/make-dmg.sh  — reuse existing dist/PinSnap.app
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCHEME="${SCHEME:-PinSnap}"
CONFIG="${CONFIG:-Release}"
IDENTITY="${CODE_SIGN_IDENTITY:-PinSnap Local Signing}"
VERSION="${VERSION:-1.0.0}"
OUT_DIR="${OUT_DIR:-$ROOT/dist}"
DMG_NAME="${DMG_NAME:-PinSnap-${VERSION}-trial.dmg}"
VOL_NAME="${VOL_NAME:-PinSnap}"
BG_SRC="${BG_SRC:-$ROOT/Resources/dmg/background.png}"
SKIP_BUILD="${SKIP_BUILD:-0}"

# Window in Finder points; background.png is 2× pixels @ 144 DPI
WIN_X=200
WIN_Y=120
WIN_W=660
WIN_H=400
ICON_SIZE=128
APP_X=160
APP_Y=185
APPS_X=500
APPS_Y=185

cd "$ROOT"

if ! command -v create-dmg >/dev/null 2>&1; then
  echo "error: create-dmg not found. Install with: brew install create-dmg" >&2
  exit 1
fi

eject_vol() {
  local name="$1"
  if [[ -d "/Volumes/$name" ]]; then
    hdiutil detach "/Volumes/$name" -force >/dev/null 2>&1 || true
  fi
}

if [[ "$SKIP_BUILD" != "1" ]]; then
  if ! security find-identity -v -p codesigning | grep -q "\"$IDENTITY\""; then
    echo "error: no valid codesigning identity named \"$IDENTITY\"." >&2
    exit 1
  fi

  xcodegen generate
  xcodebuild \
    -scheme "$SCHEME" \
    -configuration "$CONFIG" \
    -destination 'platform=macOS' \
    -derivedDataPath "$ROOT/build/DerivedData" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="$IDENTITY" \
    build

  APP="$(find "$ROOT/build/DerivedData/Build/Products/$CONFIG" -name 'PinSnap.app' -type d | head -1)"
  if [[ -z "$APP" || ! -d "$APP" ]]; then
    echo "error: PinSnap.app not found under build/DerivedData" >&2
    exit 1
  fi

  mkdir -p "$OUT_DIR"
  rm -rf "$OUT_DIR/PinSnap.app"
  ditto "$APP" "$OUT_DIR/PinSnap.app"
fi

APP_BUNDLE="$OUT_DIR/PinSnap.app"
if [[ ! -d "$APP_BUNDLE" ]]; then
  echo "error: missing $APP_BUNDLE (build first or omit SKIP_BUILD=1)" >&2
  exit 1
fi
if [[ ! -f "$BG_SRC" ]]; then
  echo "error: missing DMG background: $BG_SRC" >&2
  exit 1
fi

eject_vol "$VOL_NAME"
eject_vol "$VOL_NAME 1"

WORK="$(mktemp -d)"
STAGE="$WORK/stage"
BG_WORK="$WORK/background.png"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$STAGE"
ditto "$APP_BUNDLE" "$STAGE/PinSnap.app"

# Retina: 1320×800 px + 144 DPI ⇒ 660×400 pt (matches --window-size)
ditto "$BG_SRC" "$BG_WORK"
sips -s dpiWidth 144 -s dpiHeight 144 "$BG_WORK" >/dev/null

VOLICON="$APP_BUNDLE/Contents/Resources/AppIcon.icns"
DMG="$OUT_DIR/$DMG_NAME"
rm -f "$DMG"

create-dmg \
  --volname "$VOL_NAME" \
  --volicon "$VOLICON" \
  --background "$BG_WORK" \
  --window-pos "$WIN_X" "$WIN_Y" \
  --window-size "$WIN_W" "$WIN_H" \
  --icon-size "$ICON_SIZE" \
  --text-size 12 \
  --icon "PinSnap.app" "$APP_X" "$APP_Y" \
  --hide-extension "PinSnap.app" \
  --app-drop-link "$APPS_X" "$APPS_Y" \
  --no-internet-enable \
  --hdiutil-quiet \
  "$DMG" \
  "$STAGE"

echo "Created $DMG"
ls -lh "$DMG"
