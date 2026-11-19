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

    /// Screenshot mode sets fixed settings, so it gets throwaway defaults:
    /// a screenshot must never change the user's own preferences.
    static let shared = AppSettings(defaults: ScreenshotMode.isActive ? ScreenshotMode.defaults : .standard)

    @ObservationIgnored private let defaults: UserDefaults

    var appearance: Appearance { didSet { defaults.set(appearance.rawValue, forKey: Keys.appearance) } }
    /// The candy colours and glossy tiles of the desktop before glass, in
    /// light and dark mode alike.
    var classicColors: Bool { didSet { defaults.set(classicColors, forKey: Keys.classicColors) } }
    var palette: Palette { classicColors ? .classic : .modern }
    /// Levels of nested tiles, 1 to 8.
    var nestingDepth: Int { didSet { defaults.set(nestingDepth, forKey: Keys.depth) } }
    var showLabels: Bool { didSet { defaults.set(showLabels, forKey: Keys.labels) } }
    var showInspector: Bool { didSet { defaults.set(showInspector, forKey: Keys.inspector) } }

    private enum Keys {
        static let appearance = "appearance"
        static let classicColors = "classicColors"
        static let depth = "nestingDepth"
        static let labels = "showLabels"
        static let inspector = "showInspector"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        appearance = Appearance(rawValue: defaults.string(forKey: Keys.appearance) ?? "") ?? .system
        classicColors = defaults.bool(forKey: Keys.classicColors)
        // The six palettes of earlier builds are gone; forget the choice.
        defaults.removeObject(forKey: "palette")
        let depth = defaults.integer(forKey: Keys.depth)
        nestingDepth = depth == 0 ? 4 : min(max(depth, 1), 8)
        showLabels = defaults.object(forKey: Keys.labels) as? Bool ?? true
        showInspector = defaults.object(forKey: Keys.inspector) as? Bool ?? true
    }
}
