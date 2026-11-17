#!/bin/bash
# Archives the Swift app and exports a Mac App Store package, signed with the
# manual signing material described in docs/mac-app-store.md, then runs the
# private-API check on the result. It never uploads: send the package with
# Transporter or `xcrun altool` yourself once it has been tested.
#
# Usage: BUILD_NUMBER=26 swift/scripts/archive.sh
#   BUILD_NUMBER          required; must be higher than any build already in
#                         App Store Connect
#   PROVISIONING_PROFILE  optional; defaults to
#                         ~/.alocir-signing/Alocir_Mac_App_Store.provisionprofile
#   OUTPUT                optional; defaults to swift/build/archive
set -euo pipefail

: "${BUILD_NUMBER:?Set BUILD_NUMBER, higher than the last build in App Store Connect}"
here="$(cd "$(dirname "$0")/.." && pwd)"
repo="$(cd "$here/.." && pwd)"
profile="${PROVISIONING_PROFILE:-$HOME/.alocir-signing/Alocir_Mac_App_Store.provisionprofile}"
output="${OUTPUT:-$here/build/archive}"
team=45X6674984
bundle_id=com.jeffkroon.alocir
profile_name="Alocir Mac App Store"

[ -f "$profile" ] || { echo "Provisioning profile not found: $profile" >&2; exit 1; }

# Install the profile where Xcode looks for it, named by its UUID.
uuid=$(security cms -D -i "$profile" | plutil -extract UUID raw -o - -)
profiles="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
mkdir -p "$profiles"
cp "$profile" "$profiles/$uuid.provisionprofile"

rm -rf "$output"
mkdir -p "$output"
archive="$output/Alocir.xcarchive"

echo "==> Archiving build $BUILD_NUMBER"
xcodebuild -project "$here/Alocir.xcodeproj" -scheme Alocir -configuration Release \
    -destination 'generic/platform=macOS' -archivePath "$archive" \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="$team" \
    CODE_SIGN_IDENTITY="Apple Distribution" \
    PROVISIONING_PROFILE_SPECIFIER="$profile_name" \
    archive

cat >"$output/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key><string>app-store-connect</string>
    <key>destination</key><string>export</string>
    <key>teamID</key><string>$team</string>
    <key>signingStyle</key><string>manual</string>
    <key>signingCertificate</key><string>Apple Distribution</string>
    <key>installerSigningCertificate</key><string>3rd Party Mac Developer Installer</string>
    <key>provisioningProfiles</key>
    <dict><key>$bundle_id</key><string>$profile_name</string></dict>
    <key>uploadSymbols</key><true/>
</dict>
</plist>
PLIST

echo "==> Exporting the store package"
xcodebuild -exportArchive -archivePath "$archive" \
    -exportOptionsPlist "$output/ExportOptions.plist" -exportPath "$output"

app="$archive/Products/Applications/Alocir.app"
echo "==> Checking the archived app"
codesign --verify --strict --deep "$app"
codesign -d --entitlements - "$app" 2>/dev/null | grep -q app-sandbox \
    || { echo "The archived app is not sandboxed" >&2; exit 1; }
"$repo/scripts/check-private-apis.sh" "$app"

pkg=$(find "$output" -maxdepth 1 -name '*.pkg' | head -1)
echo ""
echo "Package: $pkg"
echo "Version $(plutil -extract CFBundleShortVersionString raw -o - "$app/Contents/Info.plist") ($BUILD_NUMBER). Not uploaded."
