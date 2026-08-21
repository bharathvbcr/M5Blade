#!/bin/bash
# Scripts/package-release.sh — Hardened release packaging for FanControl / M5Blade
#
# Packages FanControl.app into a distributable zip archive while preserving
# macOS extended attributes, permissions, and ad-hoc code signature metadata.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

APP_PATH="${1:-$ROOT_DIR/Products/FanControl.app}"
OUTPUT_DIR="${2:-$ROOT_DIR/Products}"

echo "==> Validating app bundle at: $APP_PATH"

if [ ! -d "$APP_PATH" ]; then
    echo "ERROR: App bundle not found at '$APP_PATH'. Run 'make app' first." >&2
    exit 1
fi

REQUIRED_FILES=(
    "Contents/Info.plist"
    "Contents/MacOS/FanControlApp"
    "Contents/Resources/AppIcon.icns"
    "Contents/Resources/fancontrold"
    "Contents/Resources/smcfan"
    "Contents/Resources/install-helper.sh"
    "Contents/Resources/uninstall-helper.sh"
    "Contents/Resources/com.fancontrol.helper.plist"
)

for file in "${REQUIRED_FILES[@]}"; do
    if [ ! -e "$APP_PATH/$file" ]; then
        echo "ERROR: Missing required file in app bundle: $file" >&2
        exit 1
    fi
done

# Ensure helper scripts have executable permissions
chmod +x "$APP_PATH/Contents/Resources/install-helper.sh" "$APP_PATH/Contents/Resources/uninstall-helper.sh"

echo "==> Verifying code signature..."
codesign --verify --deep --strict "$APP_PATH"
echo "    Code signature verified successfully."

mkdir -p "$OUTPUT_DIR"

ZIP_NAME_FANCONTROL="FanControl-arm64.zip"
ZIP_NAME_M5BLADE="M5Blade-arm64.zip"

ZIP_PATH_FANCONTROL="$OUTPUT_DIR/$ZIP_NAME_FANCONTROL"
ZIP_PATH_M5BLADE="$OUTPUT_DIR/$ZIP_NAME_M5BLADE"

echo "==> Packaging archive: $ZIP_NAME_FANCONTROL (using ditto to preserve resource forks & code signing)..."
rm -f "$ZIP_PATH_FANCONTROL" "$ZIP_PATH_M5BLADE"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH_FANCONTROL"
cp "$ZIP_PATH_FANCONTROL" "$ZIP_PATH_M5BLADE"

echo "==> Generating SHA256 checksums..."
(
    cd "$OUTPUT_DIR"
    shasum -a 256 "$ZIP_NAME_FANCONTROL" > "${ZIP_NAME_FANCONTROL}.sha256"
    shasum -a 256 "$ZIP_NAME_M5BLADE" > "${ZIP_NAME_M5BLADE}.sha256"
)

echo "==> Verifying archive integrity by test extraction..."
TEST_EXTRACT_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_EXTRACT_DIR"' EXIT

ditto -x -k "$ZIP_PATH_FANCONTROL" "$TEST_EXTRACT_DIR"
codesign --verify --deep --strict "$TEST_EXTRACT_DIR/FanControl.app"
echo "    Extraction and signature verification passed."

echo ""
echo "==> Release Package Built Successfully:"
echo "    - $ZIP_PATH_FANCONTROL ($(du -h "$ZIP_PATH_FANCONTROL" | cut -f1))"
echo "      SHA256: $(cat "$OUTPUT_DIR/${ZIP_NAME_FANCONTROL}.sha256" | awk '{print $1}')"
echo "    - $ZIP_PATH_M5BLADE ($(du -h "$ZIP_PATH_M5BLADE" | cut -f1))"
echo "      SHA256: $(cat "$OUTPUT_DIR/${ZIP_NAME_M5BLADE}.sha256" | awk '{print $1}')"
