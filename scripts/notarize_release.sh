#!/usr/bin/env bash
#
# notarize_release.sh — build a Release configuration of Whistral, sign with
# Developer ID Application, submit to Apple's Notary Service, staple the
# notarization ticket, and package into build/Whistral-<version>.zip.
#
# Requirements:
#   1. A "Developer ID Application: <Name> (<TeamID>)" certificate in your Keychain
#      (Xcode > Settings > Accounts > Manage Certificates > + > Developer ID Application).
#   2. A stored keychain profile in notarytool (e.g. named "notary-profile"):
#      xcrun notarytool store-credentials "notary-profile" \
#          --apple-id "your-apple-id@email.com" \
#          --team-id "<TEAM_ID>" \
#          --password "<app-specific-password>"
#
# Usage:
#   ./scripts/notarize_release.sh [notary-keychain-profile]
#   (default profile: "notary-profile")
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

PROFILE="${1:-notary-profile}"
PROJECT="Whistral.xcodeproj"
SCHEME="Whistral"
OUTPUT_DIR="$REPO_ROOT/build"
DERIVED_DATA_PATH="$OUTPUT_DIR/DerivedData"

mkdir -p "$OUTPUT_DIR"

# --- 1. Find Developer ID Application identity ------------------------------
echo "==> Looking for Developer ID Application certificate..."
SIGNING_IDENTITY=$(security find-identity -v -p codesigning | grep "Developer ID Application:" | head -n 1 | sed -E 's/.*"([^"]+)".*/\1/' || true)

if [[ -z "$SIGNING_IDENTITY" ]]; then
    echo "error: No 'Developer ID Application' certificate found in Keychain." >&2
    echo "" >&2
    echo "To get one:" >&2
    echo "  1. Open Xcode > Settings (⌘,) > Accounts" >&2
    echo "  2. Select your Apple ID > Manage Certificates..." >&2
    echo "  3. Click '+' and choose 'Developer ID Application'" >&2
    exit 1
fi

echo "==> Using identity: $SIGNING_IDENTITY"

# --- 2. Read version --------------------------------------------------------
version=""
if [[ -f "$PROJECT/project.xcproj" ]]; then
    version="$(grep -oE '"MARKETING_VERSION"[[:space:]]*:[[:space:]]*"[^"]+"' \
        "$PROJECT/project.xcproj" | head -n 1 | sed -E 's/.*"([^"]+)"$/\1/')"
elif [[ -f "$PROJECT/project.pbxproj" ]]; then
    version="$(grep -m1 -E 'MARKETING_VERSION' "$PROJECT/project.pbxproj" \
        | sed -E 's/.*=[[:space:]]*"?([^";]+)"?;?.*/\1/' | xargs)"
fi

if [[ -z "$version" ]]; then
    echo "error: could not read MARKETING_VERSION" >&2
    exit 1
fi

echo "==> Building Whistral $version Release..."
xcodebuild build \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    CODE_SIGN_STYLE="Manual" \
    CODE_SIGN_IDENTITY="$SIGNING_IDENTITY"

PRODUCTS_DIR="$DERIVED_DATA_PATH/Build/Products/Release"
APP_PATH="$(find "$PRODUCTS_DIR" -maxdepth 1 -type d -name '*.app' | head -n 1)"

if [[ -z "$APP_PATH" ]]; then
    echo "error: no .app found in $PRODUCTS_DIR" >&2
    exit 1
fi

# --- 3. Re-sign bundle with Hardened Runtime & Timestamp --------------------
echo "==> Signing app bundle with hardened runtime and timestamp..."
codesign --force --deep --options runtime --timestamp \
    --sign "$SIGNING_IDENTITY" \
    --entitlements "Whistral/Whistral.entitlements" \
    "$APP_PATH"

echo "==> Verifying signature..."
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

# --- 4. Package temporary zip for notarization submission -------------------
SUBMIT_ZIP="$OUTPUT_DIR/Whistral-notarize.zip"
rm -f "$SUBMIT_ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$SUBMIT_ZIP"

# --- 5. Submit to Apple Notary Service ---------------------------------------
echo "==> Submitting to Apple Notary Service (profile: $PROFILE)..."
xcrun notarytool submit "$SUBMIT_ZIP" --keychain-profile "$PROFILE" --wait

# --- 6. Staple the notarization ticket ---------------------------------------
echo "==> Stapling notarization ticket to $APP_PATH..."
xcrun stapler staple "$APP_PATH"

# Verify stapling
xcrun stapler validate "$APP_PATH"

# --- 7. Package final stapled release zip -----------------------------------
FINAL_ZIP="$OUTPUT_DIR/Whistral-${version}.zip"
rm -f "$FINAL_ZIP" "$SUBMIT_ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$FINAL_ZIP"

SHA256=$(shasum -a 256 "$FINAL_ZIP" | awk '{print $1}')

echo ""
echo "======================================================================"
echo " SUCCESS: Notarized Whistral ${version} release packaged!"
echo " File:   $FINAL_ZIP"
echo " SHA256: $SHA256"
echo "======================================================================"
echo "Update Casks/whistral.rb with the new SHA256 before publishing."
