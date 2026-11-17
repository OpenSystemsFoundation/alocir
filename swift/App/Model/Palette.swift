import AlocirCore
import SwiftUI

/// A colour per file kind. Generic names only (no third-party names).
enum Palette: String, CaseIterable, Identifiable, Codable {
    case spectrum, aurora, ember, ocean, graphite, phosphor

    var id: String { rawValue }

    var name: LocalizedStringKey {
        switch self {
        case .spectrum: "Spectrum"
        case .aurora: "Aurora"
        case .ember: "Ember"
        case .ocean: "Ocean"
        case .graphite: "Graphite"
        case .phosphor: "Phosphor"
        }
    }

    /// Fill for files of `kind`. Folders are drawn as frames (`folderTint`).
    func color(for kind: FileKind) -> Color {
        Color(rgb: hex(for: kind))
    }

    /// The kinds shown in the legend, in a fixed order.
    static let legendKinds: [FileKind] = [
        .image, .video, .audio, .document, .archive, .code, .application, .system, .other,
    ]

    var folderTint: Color {
        switch self {
        case .phosphor: Color(rgb: 0x1F7A3A)
        case .graphite: Color(rgb: 0x6B7280)
        case .ember: Color(rgb: 0x9A3B2E)
        case .ocean: Color(rgb: 0x1F5F8B)
        case .aurora: Color(rgb: 0x5B4B9A)
        case .spectrum: Color(rgb: 0x4A5578)
        }
    }

    private func hex(for kind: FileKind) -> UInt32 {
        let table: [UInt32]
        // Order: image, video, audio, document, archive, code, application, system, other
        switch self {
        case .spectrum:
            table = [0x34A853, 0xE5484D, 0xA855F7, 0x3B82F6, 0xF59E0B, 0x14B8A6, 0xEC4899, 0x8B95A7, 0x64748B]
        case .aurora:
            table = [0x5EEAD4, 0xC084FC, 0xF472B6, 0x60A5FA, 0xFBBF24, 0x4ADE80, 0xA78BFA, 0x94A3B8, 0x7C8AA5]
        case .ember:
            table = [0xF97316, 0xDC2626, 0xFB7185, 0xFBBF24, 0xB45309, 0xEAB308, 0xE11D48, 0xA8A29E, 0x78716C]
        case .ocean:
            table = [0x22D3EE, 0x3B82F6, 0x818CF8, 0x0EA5E9, 0x2DD4BF, 0x38BDF8, 0x6366F1, 0x94A3B8, 0x64748B]
        case .graphite:
            table = [0x9CA3AF, 0x6B7280, 0xA1A1AA, 0xD4D4D8, 0x71717A, 0xB4B4BC, 0x8E8E96, 0x5B5B63, 0x7A7A82]
        case .phosphor:
            table = [0x4ADE80, 0x22C55E, 0x86EFAC, 0xBEF264, 0x16A34A, 0xA3E635, 0x65A30D, 0x3F6212, 0x4D7C0F]
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
        let rgb = hex(for: kind)
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
