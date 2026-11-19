import AlocirCore
import SwiftUI

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(RecentFolders.self) private var recents

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section("Appearance") {
                Picker("Appearance", selection: $settings.appearance) {
                    ForEach(AppSettings.Appearance.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle(isOn: $settings.classicColors) {
                    Text("Classic colors")
                    Text("Candy colors and glossy tiles, from before glass. For light and dark mode.")
                }
                LabeledContent("Preview") {
                    PaletteStrip(palette: settings.palette)
                }
            }
            Section("Map") {
                Stepper(value: $settings.nestingDepth, in: 1...8) {
                    LabeledContent("Nesting depth", value: "\(settings.nestingDepth) levels")
                }
                Toggle("Show names and sizes on tiles", isOn: $settings.showLabels)
                Toggle("Show the inspector", isOn: $settings.showInspector)
            }
            Section("Recent Folders") {
                LabeledContent("Remembered on this Mac") {
                    Text("\(recents.entries.count)")
                        .monospacedDigit()
                }
                Button("Clear Recents", role: .destructive) { recents.clear() }
                    .disabled(recents.entries.isEmpty)
            }
            Section {
                LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")
                Link("Privacy Policy", destination: URL(string: "https://github.com/OpenSystemsFoundation/alocir/blob/main/PRIVACY.md")!)
                Link("Support", destination: URL(string: "https://github.com/OpenSystemsFoundation/alocir/issues")!)
            }
        }
        .formStyle(.grouped)
        .frame(width: 500)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// The palette's colours for each kind, drawn as the map draws its tiles.
private struct PaletteStrip: View {
    let palette: Palette

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Palette.legendKinds, id: \.self) { kind in
                RoundedRectangle(cornerRadius: palette.isClassic ? 4 : 3, style: .continuous)
                    .fill(palette.color(for: kind))
                    .overlay {
                        if palette.isClassic {
                            ClassicGel(cornerRadius: 4)
                        }
                    }
                    .frame(width: 18, height: 18)
            }
        }
        .accessibilityHidden(true)
    }
}

/// The glossy gel highlight of classic tiles, for previews.
struct ClassicGel: View {
    let cornerRadius: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(LinearGradient(
                stops: [
                    .init(color: .white.opacity(0.55), location: 0),
                    .init(color: .white.opacity(0.15), location: 0.5),
                    .init(color: .clear, location: 0.5),
                    .init(color: .white.opacity(0.18), location: 1),
                ],
                startPoint: .top, endPoint: .bottom))
    }
}
