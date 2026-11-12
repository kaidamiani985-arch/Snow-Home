#!/bin/bash
#
# Builds "Snow On Mac.app" using only the Command Line Tools.
#
# This machine has no full Xcode install, and the default CLT SDK (26.2) does
# not match the installed Swift 6.1.2 compiler. We pin the 15.5 SDK, which does.
# Metal shaders are compiled at runtime (see Sources/Shaders.swift) because the
# offline `metal` compiler ships with Xcode, not the CLT.

set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Seasons On Mac"
BUNDLE="$APP_NAME.app"
MIN_MACOS="12.0"
ARCHS=("arm64" "x86_64")

SDK="${SNOW_SDK:-/Library/Developer/CommandLineTools/SDKs/MacOSX15.5.sdk}"
if [ ! -d "$SDK" ]; then
  if [ -n "${SNOW_SDK:-}" ]; then
    echo "error: SNOW_SDK=$SNOW_SDK does not exist" >&2
    exit 1
  fi
  SDK="$(xcrun --show-sdk-path)"
fi

echo "SDK: $SDK"
echo "Target: macOS $MIN_MACOS (${ARCHS[*]})"

rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"

BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$BUILD_DIR"' EXIT
BINARIES=()

for ARCH in "${ARCHS[@]}"; do
  echo "Building $ARCH..."
  swiftc \
    -O \
    -wmo \
    -sdk "$SDK" \
    -target "${ARCH}-apple-macosx${MIN_MACOS}" \
    Sources/*.swift \
    -o "$BUILD_DIR/SnowOnMac-$ARCH"
  BINARIES+=("$BUILD_DIR/SnowOnMac-$ARCH")
done

lipo -create "${BINARIES[@]}" -output "$BUNDLE/Contents/MacOS/SnowOnMac"

cp Resources/Info.plist "$BUNDLE/Contents/Info.plist"
if [ -f Resources/Seasons.icns ]; then
  cp Resources/Seasons.icns "$BUNDLE/Contents/Resources/Seasons.icns"
fi
if [ -f Resources/Leaves.png ]; then
  cp Resources/Leaves.png "$BUNDLE/Contents/Resources/Leaves.png"
fi

# Local signing. "Snow On Mac Dev" is a self-signed certificate in the login
# keychain; using it keeps the Accessibility permission valid across rebuilds.
# Without it we fall back to an ad-hoc signature, which macOS treats as a new
# app every time.
xattr -cr "$BUNDLE" 2>/dev/null || true
IDENTITY="${SNOW_SIGN_ID:-Snow On Mac Dev}"
if security find-identity -p codesigning 2>/dev/null | grep -q "\"$IDENTITY\""; then
  codesign --force --sign "$IDENTITY" "$BUNDLE" >/dev/null 2>&1
  echo "Signed with \"$IDENTITY\""
else
  codesign --force --sign - "$BUNDLE" >/dev/null 2>&1 || true
  echo "warning: \"$IDENTITY\" not found; ad-hoc signed."
  echo "         Accessibility will need to be granted again after each rebuild."
fi

echo "Built $BUNDLE"
lipo -info "$BUNDLE/Contents/MacOS/SnowOnMac"
