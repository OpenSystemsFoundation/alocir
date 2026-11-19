import AlocirCore
import SwiftUI

/// A colour per file kind, for light and dark mode alike. Generic names only
/// (no third-party names).
///
/// - `modern`: the default, with flat tiles and a soft gloss.
/// - `classic`: the candy colours and glossy gel tiles of the desktop before
///   glass (Settings › Classic colors).
enum Palette: String, CaseIterable, Identifiable, Codable {
    case modern, classic

    var id: String { rawValue }

    var name: LocalizedStringKey {
        switch self {
        case .modern: "Modern"
        case .classic: "Classic"
        }
    }

    /// Classic tiles are drawn as glossy gel; modern ones get a soft gloss.
    var isClassic: Bool { self == .classic }

    /// Fill for files of `kind`. Folders are drawn as frames (`folderTint`).
    func color(for kind: FileKind) -> Color {
        Color(rgb: hex(for: kind))
    }

    /// The kinds shown in the legend, in a fixed order.
    static let legendKinds: [FileKind] = [
        .image, .video, .audio, .document, .archive, .code, .application, .system, .other,
    ]

    var folderTint: Color { Color(rgb: folderTintRGB) }

    private var folderTintRGB: UInt32 {
        switch self {
        case .modern: 0x4A5578
        case .classic: 0x5B7FA6
        }
    }

    /// A folder's colour: the colour of the kind of file that takes the
    /// most space in it, mixed with the folder tint so folders still read as
    /// folders, or the plain tint when it holds no files. `shade` (0–3)
    /// nudges it lighter or darker, so neighbouring folders with the same
    /// contents stay apart.
    func folderRGB(holding kind: FileKind?, shade: UInt8) -> UInt32 {
        var rgb = kind.map { Self.mix(hex(for: $0), folderTintRGB, 0.4) } ?? folderTintRGB
        switch shade & 3 {
        case 1: rgb = Self.mix(rgb, 0xFFFFFF, 0.12)
        case 2: rgb = Self.mix(rgb, 0x000000, 0.12)
        case 3: rgb = Self.mix(rgb, 0xFFFFFF, 0.22)
        default: break
        }
        return rgb
    }

    /// `a` moved `amount` (0–1) of the way to `b`, per sRGB channel.
    private static func mix(_ a: UInt32, _ b: UInt32, _ amount: Double) -> UInt32 {
        var out: UInt32 = 0
        for shift in [16, 8, 0] as [UInt32] {
            let x = Double((a >> shift) & 0xFF)
            let y = Double((b >> shift) & 0xFF)
            out |= UInt32((x + (y - x) * amount).rounded()) << shift
        }
        return out
    }

    private func hex(for kind: FileKind) -> UInt32 {
        let table: [UInt32]
        // Order: image, video, audio, document, archive, code, application, system, other
        switch self {
        case .modern:
            table = [0x34A853, 0xE5484D, 0xA855F7, 0x3B82F6, 0xF59E0B, 0x14B8A6, 0xEC4899, 0x8B95A7, 0x64748B]
        case .classic:
            // Aqua blue, lime, tangerine, grape, strawberry and graphite.
            table = [0x6CC04A, 0xE03A4E, 0x9B59D0, 0x2F87E8, 0xF39A1E, 0x23AFC0, 0xE85FA8, 0x9AA3AD, 0x7A828C]
        }
        switch kind {
        case .image: return table[0]
        case .video: return table[1]
        case .audio: return table[2]
        case .document: return table[3]
        case .archive: return table[4]
        case .code: return table[5]
        case .application: return table[6]
        case .system: return table[7]
        case .other, .directory: return table[8]
        }
    }

    /// Label colour that keeps contrast on a tile of `kind`.
    func labelColor(for kind: FileKind) -> Color {
        Self.labelColor(on: hex(for: kind))
    }

    /// Label colour that keeps contrast on a fill of `rgb`.
    static func labelColor(on rgb: UInt32) -> Color {
        let r = Double((rgb >> 16) & 0xFF) / 255, g = Double((rgb >> 8) & 0xFF) / 255, b = Double(rgb & 0xFF) / 255
        func linear(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        let luminance = 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
        // Pick whichever of black or white contrasts more.
        return (luminance + 0.05) / 0.05 > 1.05 / (luminance + 0.05) ? .black.opacity(0.85) : .white
    }
}

extension FileKind {
    var label: LocalizedStringKey {
        switch self {
        case .directory: "Folders"
        case .image: "Images"
        case .video: "Video"
        case .audio: "Audio"
        case .document: "Documents"
        case .archive: "Archives & disk images"
        case .code: "Code"
        case .application: "Apps & libraries"
        case .system: "System & data"
        case .other: "Other"
        }
    }

    var symbol: String {
        switch self {
        case .directory: "folder.fill"
        case .image: "photo"
        case .video: "film"
        case .audio: "music.note"
        case .document: "doc.text"
        case .archive: "archivebox"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .application: "app.badge"
        case .system: "gearshape"
        case .other: "doc"
        }
    }
}

extension Color {
    init(rgb: UInt32) {
        self.init(
            .sRGB,
            red: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255)
    }
}
