#!/bin/bash
# What the "Swift" CI job runs, so it can also be run by hand on a Mac:
#   ./swift/scripts/ci.sh
# Builds and tests the AlocirCore package, builds the app with xcodebuild
# (ad-hoc signed) and checks it for private APIs.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "::group::Toolchain"
xcodebuild -version
sdk=$(xcrun --sdk macosx --show-sdk-version)
echo "macOS SDK $sdk"
swift --version
echo "::endgroup::"
if [[ "${sdk%%.*}" -lt 27 ]]; then
    echo "::error::The macOS 27 SDK (Xcode 27) is required; found SDK $sdk" >&2
    exit 1
fi

echo "::group::swift build"
swift build -c release
echo "::endgroup::"

echo "::group::swift test"
swift test
echo "::endgroup::"

echo "::group::Totals: Swift vs Rust scanner"
./scripts/compare-totals.sh
echo "::endgroup::"

echo "::group::xcodebuild"
xcodebuild -project Alocir.xcodeproj -scheme Alocir -configuration Release \
    -destination 'generic/platform=macOS' -derivedDataPath build \
    CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
    build
echo "::endgroup::"

app=build/Build/Products/Release/Alocir.app
archs=$(lipo -archs "$app/Contents/MacOS/Alocir")
echo "Architectures: $archs"
# Universal: macOS 26 is the minimum and the last macOS for Intel Macs.
for arch in arm64 x86_64; do
    if [[ " $archs " != *" $arch "* ]]; then
        echo "::error::The app has no $arch slice (found: $archs)" >&2
        exit 1
    fi
done
echo "Minimum macOS: $(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$app/Contents/Info.plist")"
../scripts/check-private-apis.sh "$app"
