# Vendored winit 0.30.12

This is winit 0.30.12 from crates.io with its private macOS APIs removed.
The workspace uses it through `[patch.crates-io]` in the root `Cargo.toml`.

Alocir 1.0.0 was rejected by App Review (guideline 2.5.1) for
`_CGSSetWindowBackgroundBlurRadius`. Every winit 0.30.x has it, so upgrading
doesn't help.

## Changes

| File | Change |
|------|--------|
| `src/platform_impl/macos/ffi.rs` | Removed the `CGSMainConnectionID` and `CGSSetWindowBackgroundBlurRadius` declarations |
| `src/platform_impl/macos/window_delegate.rs` | `set_blur` is a no-op (Alocir never blurs its window) |
| `src/platform_impl/macos/cursor.rs` | Dropped the undocumented `NSCursor` selectors (`_helpCursor`, `_zoomIn/OutCursor`, `_windowResize*Cursor`, `busyButClickableCursor`). Zoom and diagonal resize cursors use the public macOS 15 APIs (`zoomInCursor`, `frameResizeCursorFromPosition:inDirections:`) when present and the arrow otherwise; Help, Wait and Progress use the arrow |
| `src/platform_impl/macos/view.rs` | Removed the `_wantsKeyDownForEvent:` override (it only let Ctrl-Tab and Ctrl-Esc through) |
| `Cargo.toml` | Dropped the `[[example]]`/`[[test]]` targets and `include` list; examples and tests aren't vendored |

Search for `Alocir:` comments to find each change.

## Updating

When egui moves to a newer winit: copy the new release from
`~/.cargo/registry/src/*/winit-<version>/` (`Cargo.toml`, `LICENSE`,
`README.md`, `build.rs`, `src`), reapply the changes above, then run
`./scripts/check-private-apis.sh` on a release build. Once winit no longer
uses private APIs, delete this folder and the `[patch.crates-io]` entry.
