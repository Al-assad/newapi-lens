#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/newapi-lens.xcodeproj"
SCHEME="newapi-lens"
APP_NAME="newapi-lens"
DEFAULT_DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"

if [[ ! -d "$DEFAULT_DEVELOPER_DIR" && -z "${DEVELOPER_DIR:-}" ]]; then
  echo "Xcode.app not found at $DEFAULT_DEVELOPER_DIR" >&2
  exit 1
fi

export DEVELOPER_DIR="${DEVELOPER_DIR:-$DEFAULT_DEVELOPER_DIR}"

MODE="${1:-universal}"
case "$MODE" in
  universal)
    ARCHS_VALUE="arm64 x86_64"
    ONLY_ACTIVE_ARCH_VALUE="NO"
    DIST_SUFFIX="mac-universal"
    ;;
  intel)
    ARCHS_VALUE="x86_64"
    ONLY_ACTIVE_ARCH_VALUE="NO"
    DIST_SUFFIX="mac-intel"
    ;;
  apple)
    ARCHS_VALUE="arm64"
    ONLY_ACTIVE_ARCH_VALUE="NO"
    DIST_SUFFIX="mac-apple-silicon"
    ;;
  *)
    echo "Usage: $0 [universal|intel|apple]" >&2
    exit 1
    ;;
esac

BUILD_ROOT="$ROOT_DIR/.build/releases/$MODE"
DIST_DIR="$ROOT_DIR/dist"
PRODUCT_DIR="$BUILD_ROOT/Build/Products/Release"
APP_PATH="$PRODUCT_DIR/$APP_NAME.app"

rm -rf "$BUILD_ROOT"
mkdir -p "$DIST_DIR"

xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -configuration Release \
  -derivedDataPath "$BUILD_ROOT" \
  build \
  CODE_SIGNING_ALLOWED=NO \
  ARCHS="$ARCHS_VALUE" \
  ONLY_ACTIVE_ARCH="$ONLY_ACTIVE_ARCH_VALUE"

if [[ ! -d "$APP_PATH" ]]; then
  echo "Build succeeded but app was not found at $APP_PATH" >&2
  exit 1
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist")"
BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_PATH/Contents/Info.plist")"
ZIP_NAME="NewAPI-Lens-${VERSION}-${BUILD_NUMBER}-${DIST_SUFFIX}.zip"
ZIP_PATH="$DIST_DIR/$ZIP_NAME"
APP_EXPORT_PATH="$DIST_DIR/NewAPI-Lens-${VERSION}-${BUILD_NUMBER}-${DIST_SUFFIX}.app"

rm -rf "$APP_EXPORT_PATH" "$ZIP_PATH"
cp -R "$APP_PATH" "$APP_EXPORT_PATH"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP_EXPORT_PATH" "$ZIP_PATH"

echo "mode=$MODE"
echo "app=$APP_EXPORT_PATH"
echo "zip=$ZIP_PATH"
lipo -info "$APP_EXPORT_PATH/Contents/MacOS/$APP_NAME"
