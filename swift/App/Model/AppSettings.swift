import SwiftUI

/// Preferences, stored in UserDefaults. Window size and position are
/// restored by the system.
@MainActor
@Observable
final class AppSettings {
    enum Appearance: String, CaseIterable, Identifiable {
        case system, light, dark
        var id: String { rawValue }
        var colorScheme: ColorScheme? {
            switch self {
            case .system: nil
            case .light: .light
            case .dark: .dark
            }
        }
        var label: LocalizedStringKey {
            switch self {
            case .system: "System"
            case .light: "Light"
            case .dark: "Dark"
            }
        }
    }

    static let shared = AppSettings()

    @ObservationIgnored private let defaults: UserDefaults

    var appearance: Appearance { didSet { defaults.set(appearance.rawValue, forKey: Keys.appearance) } }
    var palette: Palette { didSet { defaults.set(palette.rawValue, forKey: Keys.palette) } }
    /// Levels of nested tiles, 1 to 8.
    var nestingDepth: Int { didSet { defaults.set(nestingDepth, forKey: Keys.depth) } }
    var showLabels: Bool { didSet { defaults.set(showLabels, forKey: Keys.labels) } }
    var showInspector: Bool { didSet { defaults.set(showInspector, forKey: Keys.inspector) } }

    private enum Keys {
        static let appearance = "appearance"
        static let palette = "palette"
        static let depth = "nestingDepth"
        static let labels = "showLabels"
        static let inspector = "showInspector"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        appearance = Appearance(rawValue: defaults.string(forKey: Keys.appearance) ?? "") ?? .system
        palette = Palette(rawValue: defaults.string(forKey: Keys.palette) ?? "") ?? .spectrum
        let depth = defaults.integer(forKey: Keys.depth)
        nestingDepth = depth == 0 ? 4 : min(max(depth, 1), 8)
        showLabels = defaults.object(forKey: Keys.labels) as? Bool ?? true
        showInspector = defaults.object(forKey: Keys.inspector) as? Bool ?? true
    }
}
