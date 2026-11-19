/// The category a file is coloured by. Computed once by the scanner from the
/// name's extension and stored in the node, so painting never touches strings.
public enum FileKind: UInt8, Sendable, CaseIterable {
    case directory
    case other
    case image
    case video
    case audio
    case document
    case archive
    case code
    case application
    case system

    /// The kind of a file (not a directory) with this name, from its
    /// extension. Names without an extension, and hidden files such as
    /// `.zshrc` whose only dot is the first character, are `.other`.
    public init(fileName: String) {
        self = Self.kind(forExtension: Self.lowercasedExtension(of: fileName))
    }

    /// The extension after the last dot, lowercased (ASCII only), or `""`.
    /// Extensions longer than 15 bytes are ignored: no kind uses one, and
    /// shorter strings are stored inline, so this never allocates.
    static func lowercasedExtension(of name: String) -> String {
        var name = name
        return name.withUTF8 { bytes -> String in
            guard let dot = bytes.lastIndex(of: UInt8(ascii: ".")), dot > 0 else { return "" }
            let count = bytes.count - dot - 1
            guard count > 0, count <= 15 else { return "" }
            var lowered: [UInt8] = []
            lowered.reserveCapacity(count)
            for byte in bytes[(dot + 1)...] {
                lowered.append(byte >= 65 && byte <= 90 ? byte | 0x20 : byte)
            }
            return String(decoding: lowered, as: UTF8.self)
        }
    }

    static func kind(forExtension ext: String) -> FileKind {
        switch ext {
        case "jpg", "jpeg", "png", "gif", "heic", "heif", "tif", "tiff", "bmp", "webp",
            "raw", "cr2", "cr3", "nef", "arw", "dng", "svg", "psd", "ico", "icns", "avif":
            return .image
        case "mp4", "mov", "m4v", "avi", "mkv", "webm", "wmv", "flv", "mpg", "mpeg",
            "3gp", "mts", "m2ts":
            return .video
        case "mp3", "m4a", "aac", "wav", "aif", "aiff", "flac", "ogg", "opus", "wma",
            "caf", "alac", "mid", "midi", "logicx", "band":
            return .audio
        case "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "pages", "numbers", "key",
            "txt", "rtf", "md", "csv", "epub", "odt", "ods", "odp", "tex":
            return .document
        case "zip", "gz", "tgz", "bz2", "xz", "zst", "7z", "rar", "tar", "dmg", "iso",
            "pkg", "xip", "sparseimage", "sparsebundle", "img":
            return .archive
        case "swift", "c", "h", "m", "mm", "cpp", "hpp", "cc", "rs", "go", "py", "js", "ts",
            "tsx", "jsx", "java", "kt", "rb", "php", "cs", "sh", "zsh", "json", "yaml",
            "yml", "toml", "xml", "html", "css", "sql", "o", "a", "class", "jar", "wasm":
            return .code
        case "app", "appex", "framework", "dylib", "so", "exe", "dll", "bundle", "plugin",
            "kext", "xpc":
            return .application
        case "plist", "log", "db", "sqlite", "sqlite3", "cache", "tmp", "lock", "ds_store",
            "photoslibrary", "bak", "swp", "vmdk", "vdi", "qcow2":
            return .system
        default:
            return .other
        }
    }
}
