# Mac App Store release plan

Goal: ship Alocir (the `alocir` binary from `crates/alocir`) on the Mac App Store.
Developer ID signing and notarization for GitHub Releases already exist
(`scripts/build-macos.sh --sign ... --notarize`, the macOS step in
`.github/workflows/ci.yml`). The App Store build is a **second, separate path**
and must leave that one unchanged.

Team ID: `45X6674984`. Bundle ID: `com.jeffkroon.alocir` (registered, and
permanent now that the App Store Connect app record uses it).

## Status (2026-11-19)

| Step | State |
|---|---|
| A1–A4, A6: feature flag, sandbox fixes, entitlements, plist keys, CI job | ✅ Done |
| A5: `--app-store` / `--upload` in the build script | ✅ Done. Apple's validation of a local build found two errors: owner-only file permissions (fixed in the script) and a missing Intel slice. Local builds need `--universal`, which needs rustup; CI has it. |
| B1–B4: App ID, certificates, profile, app record | ✅ Done |
| B5: sandbox testing | ⏳ Next |
| B6: CI secrets | ⏳ Not set yet |
| B7–B9: listing, review notes, submission | ✅ 1.0.0 (build 24) submitted 2026-11-15 |
| Review of 1.0.0 | ❌ Rejected 2026-11-16 by Apple's automated scan: non-public API `_CGSSetWindowBackgroundBlurRadius`, from winit. Not resubmitted: the store moved to the Swift app instead, and the vendored winit that fixed it was removed. |
| 2.0.0 (Swift app) | ⏳ Build 33 submitted 2026-11-19, waiting for review. The App Store Connect version record that held 1.0.0 was renamed to 2.0.0 (an app with no release can only have one version in progress), and the 1.0.0 submission was cancelled. Listing, review notes and screenshots are in `appstore/` (`ios-release` skill: `asc.py status`). |

## 2.0.0: the native Swift app

From 2.0.0 the store app is the SwiftUI app in `swift/` (plan:
`docs/swift-rewrite.md`), built with Xcode 27 (macOS 27 SDK) for macOS 26
and later. Same bundle ID, team, certificates and profile as above; the
version is 2.0.0. It is universal (arm64 and x86_64): macOS 26 is the last
macOS for Intel Macs, and the macOS 27 SDK still builds Intel code for a
macOS 26 target. Build numbers must be higher than every earlier upload,
whatever the version: 1.0.0 went up as builds 30 and 31, so 2.0.0 starts at
32 (`CURRENT_PROJECT_VERSION`). The Rust store path below stays as it is
until 2.0.0 replaces it.

1. On the release Mac, with the signing material in `~/.alocir-signing/`:
   `BUILD_NUMBER=32 swift/scripts/archive.sh`. It archives with the
   "Apple Distribution" certificate and the "Alocir Mac App Store" profile,
   exports a package signed with "3rd Party Mac Developer Installer",
   checks the signature and sandbox, and runs `scripts/check-private-apis.sh`.
   It never uploads.
2. Test the archived app (`swift/build/archive/Alocir.xcarchive`) against the
   manual list in the 2.0.0 pull request.
3. Upload the package (`asc.py upload --pkg swift/build/archive/Alocir.pkg`
   from the repo root, with the `ios-release` skill, or Transporter), then
   update `appstore/release.json` (listing, "What's New" once a version is
   live, review notes) and push it with `asc.py metadata`. Screenshots come
   from `swift/scripts/screenshots.sh` (2560×1600 window captures of the demo
   scenes) and go up with `asc.py screenshots-upload`.

The app icon is the flat `assets/logo.svg` rendered to PNGs. A layered icon
made in Icon Composer, which macOS 26 and later show with glass effects, is still to
do.

### Private APIs (guideline 2.5.1)

App Review scans the binary's imported symbols and Objective-C selector names
for private APIs before a human looks at it. Our own code uses none, but
dependencies can: winit 0.30 calls CGS* window blur functions and
undocumented `NSCursor` selectors. `scripts/check-private-apis.sh` does a
similar scan. The Swift app's `archive.sh` and CI run it on every build. The
Rust app used a vendored winit without those calls for the 1.0 store build;
since the store gets the Swift app, the Rust app is back on upstream winit and
`build-macos.sh` only runs the check for `--app-store` builds, which no longer
pass it.

Signing material lives in `~/.alocir-signing/` on the release Mac (never in
the repo): private keys, certificates, `.p12` bundles and their password, and
`Alocir_Mac_App_Store.provisionprofile`. The certificates are also in the login
keychain. The App Store Connect API key is the one the `ios-release` skill uses.

The work splits in two:

- **Part A: code and scripts.**
- **Part B: Apple portal, credentials, local testing.** This needs the human
  and a Mac with the signing keys.

---

## Part A: code and scripts

### A1. Cargo feature `app-store`

Add an `app-store` feature to `crates/alocir` (and to `crates/shared` if code
there changes). Store builds use `--features app-store`. Default builds must
behave exactly as they do today.

### A2. Make the app work inside the App Sandbox

The App Store requires the sandbox. A sandboxed app can only read folders the
user picked in a system open dialog. Child processes inherit the sandbox.
Apple Events to other apps (such as scripting Finder) are blocked.

| Item | Where | Change |
|---|---|---|
| Moving to the trash | `crates/alocir/src/app.rs` (`trash::delete`) | On macOS the `trash` crate scripts Finder by default, which the sandbox blocks. Under `app-store`, use `trash::TrashContext` with `trash::macos::TrashContextExtMacos::set_delete_method(DeleteMethod::NsFileManager)`. |
| "Open Terminal Here" | `crates/shared/src/context_menu.rs`, `file_ops.rs` | Hide the menu item under `app-store`. It is unlikely to work sandboxed and is an App Review risk. |
| New window / instance | `spawn_new_instance` in `crates/alocir/src/app.rs` | Running `current_exe()` directly bypasses LaunchServices. On macOS, find the `.app` bundle from `current_exe()` (three directories up from `Contents/MacOS/alocir`) and run `open -n <bundle>`. Fall back to the current behaviour when not running from a bundle. This works in both builds. |
| "Open" / "Reveal in Finder" | `crates/shared/src/file_ops.rs` (`open`, `open -R`) | Leave as is. Flag it in the PR for local sandbox testing (B5). |
| Picking a folder | `crates/alocir/src/main.rs` (`rfd::FileDialog::pick_folder`) | Already sandbox-friendly, because the system dialog grants access. Make sure no code path reads a path the user didn't pick: home-directory listings, `/Volumes`, cloud-storage auto-detection, any start-screen folder tree. Grep for `read_dir`, `home_dir`, `/Volumes` and hard-coded paths. Under `app-store`, remove or gate whatever you find. |
| Permission errors | `crates/shared/src/scanner.rs` | Symlinks pointing outside the chosen folder will now fail with permission errors. Check they are skipped quietly (as `read_dir` errors already are) and never crash or stop the scan. |
| Full Disk Access hint | start screen | Optional, under `app-store`: a short note that scanning the whole disk requires granting Alocir Full Disk Access in System Settings → Privacy & Security. |

Out of scope for now: security-scoped bookmarks. They're only needed once the
app remembers folders between launches, which is a roadmap item.

The `crates/explorer` binary does not ship to the store. Leave it alone.

### A3. Entitlements file: `macos/Alocir.entitlements`

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key>
    <true/>
    <key>com.apple.security.files.user-selected.read-write</key>
    <true/>
    <key>com.apple.application-identifier</key>
    <string>45X6674984.com.jeffkroon.alocir</string>
    <key>com.apple.developer.team-identifier</key>
    <string>45X6674984</string>
</dict>
</plist>
```

Add nothing else: the app needs no network access and no JIT. The last two
keys are required for TestFlight on macOS and must match the provisioning
profile.

### A4. Info.plist keys

Add these to `macos/Info.plist`. Both are harmless for the Developer ID build.

- `LSApplicationCategoryType` = `public.app-category.utilities`
- `ITSAppUsesNonExemptEncryption` = `false`

### A5. `--app-store` mode in `scripts/build-macos.sh`

Add `--app-store`, combined with `--universal`. It must:

1. Build with `--features app-store` (both architecture slices).
2. Set `CFBundleVersion` to `$BUILD_NUMBER` when that is set. Every App Store
   upload needs a higher build number. `CFBundleShortVersionString` stays as
   the crate version.
3. Copy `$PROVISIONING_PROFILE` to `Contents/embedded.provisionprofile`, and
   fail clearly if it is missing.
4. Sign with
   `codesign --force --options runtime --timestamp --entitlements macos/Alocir.entitlements -s "$APP_SIGN_IDENTITY"`.
   The identity is `Apple Distribution: Jeff Kroon (45X6674984)`.
5. Build `target/release/Alocir.pkg` with
   `productbuild --component Alocir.app /Applications --sign "$INSTALLER_SIGN_IDENTITY" Alocir.pkg`.
   The identity is `3rd Party Mac Developer Installer: Jeff Kroon (45X6674984)`.
6. When `--upload` is passed, validate and then upload with
   `xcrun altool --validate-app` / `--upload-app -t macos -f Alocir.pkg`,
   authenticating with `--apiKey "$APPLE_API_KEY_ID" --apiIssuer "$APPLE_API_ISSUER_ID" --p8-file-path "$APPLE_API_KEY_PATH"`.
7. Make every bundle file world-readable before signing; the store rejects
   owner-only files (error 90255).
8. Never combine with `--notarize`. The App Store does its own processing.

Update the usage comment at the top of the script.

### A6. Optional: CI job

Add an `app-store` job to `.github/workflows/ci.yml` that runs only on
`workflow_dispatch` (manual trigger) on `macos-latest`. It should import both
certificates into a temporary keychain, the same way the Developer ID step
does, then run `build-macos.sh --universal --app-store --upload` with
`BUILD_NUMBER=${{ github.run_number }}`.

Expected secrets (the human creates these in B6):

- `MAS_APP_CERT_P12`, `MAS_INSTALLER_CERT_P12`, `MAS_CERT_PASSWORD`
- `MAS_PROVISIONING_PROFILE` (base64)
- The existing `APPLE_API_KEY_P8`, `APPLE_API_KEY_ID`, `APPLE_API_ISSUER_ID`

Skip the job cleanly if the secrets are missing.

### Constraints for Part A

- Run `cargo fmt --all` and
  `cargo clippy --workspace --all-targets -- -D warnings` before committing.
  Code gated on macOS isn't linted on Linux, so check it carefully. The PR's
  macOS CI build catches compile errors.
- Also check that `cargo build --features app-store -p alocir` compiles.
- The default build and the Developer ID / notarize path must keep working
  unchanged.
- In the PR description, list what still needs manual sandbox testing on a Mac.

---

## Part B: manual and local steps (human, on the Mac)

- **B1. Register the App ID.** ✅ Done: `com.jeffkroon.alocir` is registered
  through the App Store Connect API (Apple lists it as platform "Universal").
- **B2. Certificates.** ✅ Done through the API: "Apple Distribution: Jeff
  Kroon (45X6674984)" and "3rd Party Mac Developer Installer: Jeff Kroon
  (45X6674984)". Both expire 2027-11-15.
- **B3. Provisioning profile.** ✅ Done: "Alocir Mac App Store" (type
  `MAC_APP_STORE`), expires 2027-11-15. Its entitlements match
  `macos/Alocir.entitlements`.
- **B4. App Store Connect record.** ✅ Done.
- **B5. Sandbox testing.** A build signed for the store doesn't launch
  locally. Either install it through TestFlight, or run a store-feature build
  signed with the sandbox entitlements and a development identity. Watch for
  denials with
  `log stream --predicate 'eventMessage CONTAINS "Sandbox" AND eventMessage CONTAINS "deny"'`.
  Test picking and scanning a folder, moving to the trash, renaming, open,
  reveal, the folder watcher, and opening a new instance. Then upload a build
  and test through TestFlight.
- **B6. CI secrets.** Set them with `gh secret set`, if A6 was done.
- **B7. Store listing.**
  - Description, keywords, support URL
  - Privacy policy URL (required)
  - Screenshots at 16:10: 1280×800, 1440×900, 2560×1600 or 2880×1800
  - Category Utilities, age rating, price
  - App Privacy questionnaire: "Data not collected"
  - Export compliance answer
- **B8. Review notes.** Explain that Alocir only reads folders the user picks,
  and that whole-disk scans need the user to grant Full Disk Access.
- **B9. Submit for review.**
