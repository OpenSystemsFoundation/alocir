#!/bin/bash
set -euo pipefail

# Build a signed macOS .app bundle for Alocir.
# Usage: ./scripts/build-macos.sh [--sign IDENTITY] [--universal] [--notarize]
#        ./scripts/build-macos.sh --app-store [--universal] [--upload]
#   --sign IDENTITY   Code-sign with the given identity (e.g. "Developer ID Application: ...")
#                     Defaults to ad-hoc signing (-) if omitted. A real identity
#                     signs with the hardened runtime and a secure timestamp,
#                     both of which notarization requires.
#   --universal       Build a universal binary (arm64 + x86_64) so the app runs
#                     natively on both Apple Silicon and Intel Macs. Without this
#                     flag the app is built for the host architecture only.
#   --notarize        Submit the signed app to Apple's notary service, wait for
#                     the result and staple the ticket to the bundle. Requires
#                     --sign with a Developer ID identity and one of:
#                       NOTARY_PROFILE=<name>   a keychain profile created with
#                                               `xcrun notarytool store-credentials`
#                       APPLE_API_KEY_PATH, APPLE_API_KEY_ID, APPLE_API_ISSUER_ID
#                                               an App Store Connect API key (.p8)
#
# Mac App Store build (separate from the Developer ID path above):
#   --app-store       Build with the `app-store` Cargo feature, embed the
#                     provisioning profile, sign with the App Sandbox
#                     entitlements (macos/Alocir.entitlements) and package a
#                     signed target/release/Alocir.pkg. Reads:
#                       APP_SIGN_IDENTITY        "Apple Distribution: ..."
#                       INSTALLER_SIGN_IDENTITY  "3rd Party Mac Developer Installer: ..."
#                       PROVISIONING_PROFILE     path to the Mac App Store profile
#                       BUILD_NUMBER             optional; must grow with every upload
#                                                (defaults to the crate version)
#   --upload          After --app-store, validate and upload the .pkg to App
#                     Store Connect. Needs APPLE_API_KEY_PATH, APPLE_API_KEY_ID
#                     and APPLE_API_ISSUER_ID.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/target/release"
BUNDLE_DIR="$BUILD_DIR/Alocir.app"
SIGN_IDENTITY="-"
UNIVERSAL=false
NOTARIZE=false
APP_STORE=false
UPLOAD=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --sign) SIGN_IDENTITY="$2"; shift 2 ;;
        --universal) UNIVERSAL=true; shift ;;
        --notarize) NOTARIZE=true; shift ;;
        --app-store) APP_STORE=true; shift ;;
        --upload) UPLOAD=true; shift ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# Fail early, before a long build, if notarization can't possibly work.
NOTARY_AUTH=()
if $NOTARIZE; then
    if [[ "$SIGN_IDENTITY" == "-" ]]; then
        echo "Error: --notarize requires --sign with a Developer ID Application identity."
        exit 1
    fi
    if [[ -n "${NOTARY_PROFILE:-}" ]]; then
        NOTARY_AUTH=(--keychain-profile "$NOTARY_PROFILE")
    elif [[ -n "${APPLE_API_KEY_PATH:-}" && -n "${APPLE_API_KEY_ID:-}" && -n "${APPLE_API_ISSUER_ID:-}" ]]; then
        NOTARY_AUTH=(--key "$APPLE_API_KEY_PATH" --key-id "$APPLE_API_KEY_ID" --issuer "$APPLE_API_ISSUER_ID")
    else
        echo "Error: --notarize needs NOTARY_PROFILE, or APPLE_API_KEY_PATH + APPLE_API_KEY_ID + APPLE_API_ISSUER_ID."
        exit 1
    fi
fi

if $APP_STORE; then
    if $NOTARIZE; then
        echo "Error: --app-store and --notarize are separate paths; the App Store does its own processing."
        exit 1
    fi
    for var in APP_SIGN_IDENTITY INSTALLER_SIGN_IDENTITY PROVISIONING_PROFILE; do
        if [[ -z "${!var:-}" ]]; then
            echo "Error: --app-store needs $var."
            exit 1
        fi
    done
    if [[ ! -f "$PROVISIONING_PROFILE" ]]; then
        echo "Error: PROVISIONING_PROFILE not found: $PROVISIONING_PROFILE"
        exit 1
    fi
    SIGN_IDENTITY="$APP_SIGN_IDENTITY"
elif $UPLOAD; then
    echo "Error: --upload only works with --app-store."
    exit 1
fi
if $UPLOAD; then
    for var in APPLE_API_KEY_PATH APPLE_API_KEY_ID APPLE_API_ISSUER_ID; do
        if [[ -z "${!var:-}" ]]; then
            echo "Error: --upload needs $var."
            exit 1
        fi
    done
fi

# Only the shipped app is built; the store build turns on its feature flag.
CARGO_ARGS=(--release -p alocir)
if $APP_STORE; then
    CARGO_ARGS+=(--features app-store)
fi

VERSION=$(grep -m1 '^version' "$PROJECT_DIR/crates/alocir/Cargo.toml" | sed 's/.*"\(.*\)".*/\1/')

if $UNIVERSAL; then
    echo "==> Building universal binary (arm64 + x86_64)..."
    # rustup is absent with e.g. Homebrew's rust; cargo then fails clearly
    # if a target's standard library isn't installed.
    if command -v rustup &>/dev/null; then
        rustup target add aarch64-apple-darwin x86_64-apple-darwin
    fi
    cargo build "${CARGO_ARGS[@]}" --target aarch64-apple-darwin
    cargo build "${CARGO_ARGS[@]}" --target x86_64-apple-darwin
    # Fuse the two architecture slices into a single universal binary.
    mkdir -p "$BUILD_DIR"
    lipo -create \
        "$PROJECT_DIR/target/aarch64-apple-darwin/release/alocir" \
        "$PROJECT_DIR/target/x86_64-apple-darwin/release/alocir" \
        -output "$BUILD_DIR/alocir"
    echo "    Universal binary architectures:"
    lipo -archs "$BUILD_DIR/alocir" | sed 's/^/      /'
else
    echo "==> Building release binary..."
    cargo build "${CARGO_ARGS[@]}"
fi

# App Review rejects binaries that use private APIs, so a store build stops
# here, before signing or uploading. Upstream winit uses some (1.0.0 was
# rejected for one), so this store path no longer passes: the Mac App Store
# gets the Swift app in swift/ now. Developer ID builds don't need the check.
if $APP_STORE; then
    "$SCRIPT_DIR/check-private-apis.sh" "$BUILD_DIR/alocir"
fi

echo "==> Creating app bundle..."
rm -rf "$BUNDLE_DIR"
mkdir -p "$BUNDLE_DIR/Contents/MacOS"
mkdir -p "$BUNDLE_DIR/Contents/Resources"

# Copy binary
cp "$BUILD_DIR/alocir" "$BUNDLE_DIR/Contents/MacOS/alocir"

# Copy Info.plist
cp "$PROJECT_DIR/macos/Info.plist" "$BUNDLE_DIR/Contents/Info.plist"
# Stamp the crate version into the bundle so Finder and Gatekeeper report it.
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$BUNDLE_DIR/Contents/Info.plist"
# The build number must increase with every App Store upload.
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${BUILD_NUMBER:-$VERSION}" "$BUNDLE_DIR/Contents/Info.plist"

if $APP_STORE; then
    # The source profile may be private (0600); the store rejects bundle
    # files that only their owner can read.
    install -m 0644 "$PROVISIONING_PROFILE" "$BUNDLE_DIR/Contents/embedded.provisionprofile"
fi

# Generate .icns from SVG
echo "==> Generating app icon..."
ICONSET_DIR=$(mktemp -d)/AppIcon.iconset
mkdir -p "$ICONSET_DIR"

# Use sips to convert SVG -> PNG at required sizes.
# sips can't read SVG directly, so we use the built-in qlmanage or a temp PNG.
# Try qlmanage first (available on macOS), fall back to a simple approach.
SVG="$PROJECT_DIR/assets/logo.svg"
TEMP_PNG=$(mktemp /tmp/alocir_icon_XXXXXX.png)

if command -v rsvg-convert &>/dev/null; then
    rsvg-convert -w 1024 -h 1024 "$SVG" -o "$TEMP_PNG"
elif command -v qlmanage &>/dev/null; then
    # qlmanage generates a preview; extract the PNG.
    TEMP_QL_DIR=$(mktemp -d)
    qlmanage -t -s 1024 -o "$TEMP_QL_DIR" "$SVG" &>/dev/null || true
    QL_PNG=$(find "$TEMP_QL_DIR" -name "*.png" | head -1)
    if [[ -n "$QL_PNG" && -f "$QL_PNG" ]]; then
        cp "$QL_PNG" "$TEMP_PNG"
    else
        echo "Warning: Could not convert SVG to PNG. Skipping .icns generation."
        echo "         Install librsvg (brew install librsvg) for best results."
        TEMP_PNG=""
    fi
    rm -rf "$TEMP_QL_DIR"
else
    echo "Warning: No SVG converter found. Skipping .icns generation."
    echo "         Install librsvg (brew install librsvg) for best results."
    TEMP_PNG=""
fi

if [[ -n "$TEMP_PNG" && -f "$TEMP_PNG" ]]; then
    for SIZE in 16 32 64 128 256 512 1024; do
        sips -z $SIZE $SIZE "$TEMP_PNG" --out "$ICONSET_DIR/icon_${SIZE}x${SIZE}.png" &>/dev/null
    done
    # macOS expects @2x variants
    cp "$ICONSET_DIR/icon_32x32.png"   "$ICONSET_DIR/icon_16x16@2x.png"
    cp "$ICONSET_DIR/icon_64x64.png"   "$ICONSET_DIR/icon_32x32@2x.png"
    cp "$ICONSET_DIR/icon_256x256.png" "$ICONSET_DIR/icon_128x128@2x.png"
    cp "$ICONSET_DIR/icon_512x512.png" "$ICONSET_DIR/icon_256x256@2x.png"
    cp "$ICONSET_DIR/icon_1024x1024.png" "$ICONSET_DIR/icon_512x512@2x.png"
    # Remove non-standard sizes
    rm -f "$ICONSET_DIR/icon_64x64.png" "$ICONSET_DIR/icon_1024x1024.png"

    iconutil -c icns "$ICONSET_DIR" -o "$BUNDLE_DIR/Contents/Resources/AppIcon.icns"
    echo "    Icon generated."
    rm -f "$TEMP_PNG"
fi

# Sign the bundle. The bundle holds a single executable, so --deep isn't
# needed (Apple discourages it). Real identities get the hardened runtime and
# a secure timestamp, which notarization requires.
echo "==> Signing with identity: $SIGN_IDENTITY"
# Everything readable by everyone, whatever the umask was (App Store
# validation rejects bundles with owner-only files; error 90255).
chmod -R u+rwX,go+rX,go-w "$BUNDLE_DIR"
if [[ "$SIGN_IDENTITY" == "-" ]]; then
    codesign --force -s - "$BUNDLE_DIR"
elif $APP_STORE; then
    codesign --force --options runtime --timestamp \
        --entitlements "$PROJECT_DIR/macos/Alocir.entitlements" \
        -s "$SIGN_IDENTITY" "$BUNDLE_DIR"
else
    codesign --force --options runtime --timestamp -s "$SIGN_IDENTITY" "$BUNDLE_DIR"
fi
codesign --verify --strict --verbose=2 "$BUNDLE_DIR"

if $NOTARIZE; then
    echo "==> Submitting to Apple notary service (this usually takes a few minutes)..."
    SUBMIT_DIR=$(mktemp -d)
    SUBMIT_ZIP="$SUBMIT_DIR/Alocir.zip"
    ditto -c -k --keepParent "$BUNDLE_DIR" "$SUBMIT_ZIP"
    SUBMIT_OUT="$SUBMIT_DIR/submit.json"
    if ! xcrun notarytool submit "$SUBMIT_ZIP" "${NOTARY_AUTH[@]}" --wait \
            --output-format json > "$SUBMIT_OUT"; then
        cat "$SUBMIT_OUT" || true
    fi
    STATUS=$(/usr/bin/plutil -extract status raw "$SUBMIT_OUT" 2>/dev/null || echo unknown)
    SUBMISSION_ID=$(/usr/bin/plutil -extract id raw "$SUBMIT_OUT" 2>/dev/null || echo "")
    echo "    Status: $STATUS (submission $SUBMISSION_ID)"
    if [[ "$STATUS" != "Accepted" ]]; then
        if [[ -n "$SUBMISSION_ID" ]]; then
            echo "==> Notary log:"
            xcrun notarytool log "$SUBMISSION_ID" "${NOTARY_AUTH[@]}" || true
        fi
        rm -rf "$SUBMIT_DIR"
        echo "Error: notarization failed."
        exit 1
    fi
    rm -rf "$SUBMIT_DIR"

    echo "==> Stapling notarization ticket..."
    xcrun stapler staple "$BUNDLE_DIR"
    xcrun stapler validate "$BUNDLE_DIR"
    spctl --assess --type execute --verbose=2 "$BUNDLE_DIR"
fi

if $APP_STORE; then
    PKG="$BUILD_DIR/Alocir.pkg"
    echo "==> Building installer package..."
    rm -f "$PKG"
    productbuild --component "$BUNDLE_DIR" /Applications \
        --sign "$INSTALLER_SIGN_IDENTITY" "$PKG"
    pkgutil --check-signature "$PKG" | head -3

    if $UPLOAD; then
        ALTOOL_AUTH=(--apiKey "$APPLE_API_KEY_ID" --apiIssuer "$APPLE_API_ISSUER_ID"
            --p8-file-path "$APPLE_API_KEY_PATH")
        echo "==> Validating with App Store Connect..."
        xcrun altool --validate-app -t macos -f "$PKG" "${ALTOOL_AUTH[@]}"
        echo "==> Uploading to App Store Connect..."
        xcrun altool --upload-app -t macos -f "$PKG" "${ALTOOL_AUTH[@]}"
        echo "    Uploaded. The build appears in App Store Connect and TestFlight after processing."
    fi
    echo ""
    echo "==> Done! Installer package created at:"
    echo "    $PKG"
    exit 0
fi

echo ""
echo "==> Done! App bundle created at:"
echo "    $BUNDLE_DIR"
echo ""
echo "    To install: cp -r \"$BUNDLE_DIR\" /Applications/"
