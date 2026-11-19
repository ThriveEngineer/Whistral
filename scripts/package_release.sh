#!/usr/bin/env bash
#
# package_release.sh — build a Release configuration of Whistral and package
# the resulting .app into a zip: build/Whistral-<version>.zip
#
# Usage:
#   ./scripts/package_release.sh
#
# Environment variables:
#   WHISTRAL_DERIVED_DATA   Override the DerivedData directory
#                           (default: <repo>/build/DerivedData)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

PROJECT="Whistral.xcodeproj"
SCHEME="Whistral"
DERIVED_DATA_PATH="${WHISTRAL_DERIVED_DATA:-$REPO_ROOT/build/DerivedData}"
OUTPUT_DIR="$REPO_ROOT/build"

mkdir -p "$OUTPUT_DIR"

# --- Read MARKETING_VERSION from the project -------------------------------
# Supports both the JSON project format (project.xcproj) and the classic
# pbxproj format (project.pbxproj).
version=""

if [[ -f "$PROJECT/project.xcproj" ]]; then
    version="$(grep -oE '"MARKETING_VERSION"[[:space:]]*:[[:space:]]*"[^"]+"' \
        "$PROJECT/project.xcproj" \
        | head -n 1 \
        | sed -E 's/.*"([^"]+)"$/\1/')"
elif [[ -f "$PROJECT/project.pbxproj" ]]; then
    version="$(grep -m1 -E 'MARKETING_VERSION' "$PROJECT/project.pbxproj" \
        | sed -E 's/.*=[[:space:]]*"?([^";]+)"?;?.*/\1/' \
        | xargs)"
fi

if [[ -z "$version" ]]; then
    echo "error: could not read MARKETING_VERSION from $PROJECT" >&2
    exit 1
fi

ZIP_PATH="$OUTPUT_DIR/Whistral-${version}.zip"

# --- Release version sanity --------------------------------------------------
# CI sets WHISTRAL_EXPECTED_VERSION from the pushed tag. A forgotten
# MARKETING_VERSION bump must fail the release loudly instead of silently
# producing e.g. Whistral-1.0.zip for tag v0.1.0. Standalone local runs that
# do not set the variable are not gated (no hard-fail for local builds).
if [[ -n "${WHISTRAL_EXPECTED_VERSION:-}" && "$version" != "$WHISTRAL_EXPECTED_VERSION" ]]; then
    echo "error: MARKETING_VERSION ($version) does not match the expected release version (WHISTRAL_EXPECTED_VERSION=$WHISTRAL_EXPECTED_VERSION). Bump MARKETING_VERSION in the Xcode project to match the tag before releasing." >&2
    exit 1
fi

echo "==> Building Release (arm64), version $version"
xcodebuild build \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    | tee "$OUTPUT_DIR/xcodebuild.log"

# --- Locate the built .app ---------------------------------------------------
PRODUCTS_DIR="$DERIVED_DATA_PATH/Build/Products/Release"
APP_PATH="$(find "$PRODUCTS_DIR" -maxdepth 1 -type d -name '*.app' 2>/dev/null | head -n 1)"

if [[ -z "$APP_PATH" ]]; then
    echo "error: no .app found in $PRODUCTS_DIR" >&2
    exit 1
fi

# --- Zip it ------------------------------------------------------------------
echo "==> Packaging $(basename "$APP_PATH") -> $ZIP_PATH"
rm -f "$ZIP_PATH"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"

echo "==> Done: $ZIP_PATH"
