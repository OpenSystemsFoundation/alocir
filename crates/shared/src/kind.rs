//! What kind of file a node is, from its extension. Computed once by the
//! scanner and stored in the node, so painting never looks at names. The
//! table matches the Mac edition's `FileKind.swift`, so both editions group
//! files the same way.

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Default)]
#[repr(u8)]
pub enum FileKind {
    Directory,
    #[default]
    Other,
    Image,
    Video,
    Audio,
    Document,
    Archive,
    Code,
    Application,
    System,
}

impl FileKind {
    /// Every kind a file can have (not `Directory`), in legend order.
    pub const FILES: [FileKind; 9] = [
        FileKind::Video,
        FileKind::Archive,
        FileKind::System,
        FileKind::Code,
        FileKind::Document,
        FileKind::Image,
        FileKind::Audio,
        FileKind::Application,
        FileKind::Other,
    ];

    /// Number of variants, for arrays indexed by `kind as usize`.
    pub const COUNT: usize = 10;

    /// The kind of a file (not a directory) with this name. Names without an
    /// extension, and hidden files such as `.zshrc` whose only dot is the
    /// first character, are `Other`.
    pub fn from_name(name: &str) -> FileKind {
        let bytes = name.as_bytes();
        let Some(dot) = bytes.iter().rposition(|&b| b == b'.') else {
            return FileKind::Other;
        };
        if dot == 0 {
            return FileKind::Other;
        }
        let ext = &bytes[dot + 1..];
        // No kind uses a longer extension; this also keeps the lowercase
        // copy on the stack.
        if ext.is_empty() || ext.len() > 15 {
            return FileKind::Other;
        }
        let mut lower = [0u8; 15];
        for (i, &b) in ext.iter().enumerate() {
            lower[i] = b.to_ascii_lowercase();
        }
        Self::from_extension(&lower[..ext.len()])
    }

    fn from_extension(ext: &[u8]) -> FileKind {
        match ext {
            b"jpg" | b"jpeg" | b"png" | b"gif" | b"heic" | b"heif" | b"tif" | b"tiff" | b"bmp"
            | b"webp" | b"raw" | b"cr2" | b"cr3" | b"nef" | b"arw" | b"dng" | b"svg" | b"psd"
            | b"ico" | b"icns" | b"avif" => FileKind::Image,
            b"mp4" | b"mov" | b"m4v" | b"avi" | b"mkv" | b"webm" | b"wmv" | b"flv" | b"mpg"
            | b"mpeg" | b"3gp" | b"mts" | b"m2ts" => FileKind::Video,
            b"mp3" | b"m4a" | b"aac" | b"wav" | b"aif" | b"aiff" | b"flac" | b"ogg" | b"opus"
            | b"wma" | b"caf" | b"alac" | b"mid" | b"midi" | b"logicx" | b"band" => FileKind::Audio,
            b"pdf" | b"doc" | b"docx" | b"xls" | b"xlsx" | b"ppt" | b"pptx" | b"pages"
            | b"numbers" | b"key" | b"txt" | b"rtf" | b"md" | b"csv" | b"epub" | b"odt"
            | b"ods" | b"odp" | b"tex" => FileKind::Document,
            b"zip" | b"gz" | b"tgz" | b"bz2" | b"xz" | b"zst" | b"7z" | b"rar" | b"tar"
            | b"dmg" | b"iso" | b"pkg" | b"xip" | b"sparseimage" | b"sparsebundle" | b"img" => {
                FileKind::Archive
            }
            b"swift" | b"c" | b"h" | b"m" | b"mm" | b"cpp" | b"hpp" | b"cc" | b"rs" | b"go"
            | b"py" | b"js" | b"ts" | b"tsx" | b"jsx" | b"java" | b"kt" | b"rb" | b"php"
            | b"cs" | b"sh" | b"zsh" | b"json" | b"yaml" | b"yml" | b"toml" | b"xml" | b"html"
            | b"css" | b"sql" | b"o" | b"a" | b"class" | b"jar" | b"wasm" => FileKind::Code,
            b"app" | b"appex" | b"framework" | b"dylib" | b"so" | b"exe" | b"dll" | b"bundle"
            | b"plugin" | b"kext" | b"xpc" => FileKind::Application,
            b"plist" | b"log" | b"db" | b"sqlite" | b"sqlite3" | b"cache" | b"tmp" | b"lock"
            | b"ds_store" | b"photoslibrary" | b"bak" | b"swp" | b"vmdk" | b"vdi" | b"qcow2" => {
                FileKind::System
            }
            _ => FileKind::Other,
        }
    }

    /// Name shown in the inspector's breakdown.
    pub fn label(self) -> &'static str {
        match self {
            FileKind::Directory => "Folders",
            FileKind::Other => "Other",
            FileKind::Image => "Images",
            FileKind::Video => "Video",
            FileKind::Audio => "Audio",
            FileKind::Document => "Documents",
            FileKind::Archive => "Archives & disk images",
            FileKind::Code => "Code",
            FileKind::Application => "Applications",
            FileKind::System => "System & data",
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn extensions_ignore_case() {
        assert_eq!(FileKind::from_name("Clip.MOV"), FileKind::Video);
        assert_eq!(FileKind::from_name("photo.HeIc"), FileKind::Image);
        assert_eq!(FileKind::from_name("a.tar.gz"), FileKind::Archive);
    }

    #[test]
    fn names_without_a_usable_extension_are_other() {
        assert_eq!(FileKind::from_name("Makefile"), FileKind::Other);
        assert_eq!(FileKind::from_name(".zshrc"), FileKind::Other);
        assert_eq!(FileKind::from_name("trailing."), FileKind::Other);
        assert_eq!(
            FileKind::from_name("x.averyveryverylongextension"),
            FileKind::Other
        );
        assert_eq!(FileKind::from_name("ünïcödé.Ω"), FileKind::Other);
    }

    #[test]
    fn every_category_is_reachable() {
        for (name, kind) in [
            ("a.png", FileKind::Image),
            ("a.mkv", FileKind::Video),
            ("a.flac", FileKind::Audio),
            ("a.pdf", FileKind::Document),
            ("a.dmg", FileKind::Archive),
            ("a.rs", FileKind::Code),
            ("a.dylib", FileKind::Application),
            ("a.sqlite", FileKind::System),
        ] {
            assert_eq!(FileKind::from_name(name), kind, "{name}");
        }
    }
}
