#!/bin/sh
# Builds a universal ForceMiddleClick.app. Set SIGN_ID to a codesigning identity to keep the
# Accessibility grant across rebuilds; the default ad-hoc signature changes every build.
set -e
cd "$(dirname "$0")"

APP=ForceMiddleClick.app
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

for ARCH in arm64 x86_64; do
    swiftc -O -swift-version 5 -target "$ARCH-apple-macos13" ForceMiddleClick.swift -o "$TMP/$ARCH"
done

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
lipo -create "$TMP/arm64" "$TMP/x86_64" -output "$APP/Contents/MacOS/ForceMiddleClick"
cp Info.plist "$APP/Contents/"
codesign --force --sign "${SIGN_ID:--}" "$APP"
echo "Built $APP"
