//! Symbols used as icons. egui draws all text with its own bundled fonts on
//! every platform, so a glyph that exists there renders the same on macOS,
//! Windows and Linux; a test in `theme.rs` checks each one is present.

pub const UP: &str = "\u{2B06}"; // upwards arrow
pub const RESCAN: &str = "\u{27F3}"; // clockwise gapped circle arrow
pub const NEW_SCAN: &str = "\u{1F5C1}"; // open folder
pub const SETTINGS: &str = "\u{2699}"; // gear
pub const FOLDER: &str = "\u{1F5C0}"; // folder
pub const CHEVRON: &str = "\u{203A}"; // single right angle quote, the breadcrumb separator
pub const CHECK: &str = "\u{2714}"; // heavy check mark
pub const ELLIPSIS: &str = "\u{2026}";
pub const DOT: &str = "\u{00B7}"; // middle dot
pub const TRASH: &str = "\u{1F5D1}";
pub const WARNING: &str = "\u{26A0}";
pub const SEARCH: &str = "\u{1F50D}"; // left-pointing magnifying glass
pub const INSPECTOR: &str = "\u{2139}"; // information source
pub const EYE: &str = "\u{1F441}";
pub const CLOSE: &str = "\u{00D7}"; // multiplication sign
pub const FILE: &str = "\u{1F5CB}"; // empty document
pub const HOME: &str = "\u{1F3E0}";
pub const DISK: &str = "\u{1F5B4}"; // hard disk

/// Every glyph above plus the keyboard symbols used in shortcut hints.
pub const ALL: &str = "\u{1F50D}\u{2139}\u{1F441}\u{00D7}\u{1F5CB}\u{1F3E0}\u{1F5B4}\u{2B06}\u{27F3}\u{1F5C1}\u{2699}\u{1F5C0}\u{2714}\u{2026}\u{00B7}\u{26A0}\u{1F5D1}\u{2318}\u{203A}";
