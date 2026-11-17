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
                LabeledContent("Colours") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Palette.allCases) { palette in
                            PaletteRow(palette: palette, selected: settings.palette == palette) {
                                settings.palette = palette
                            }
                        }
                    }
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

private struct PaletteRow: View {
    let palette: Palette
    let selected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(spacing: 10) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                HStack(spacing: 2) {
                    ForEach(Palette.legendKinds, id: \.self) { kind in
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(palette.color(for: kind))
                            .frame(width: 16, height: 16)
                    }
                }
                Text(palette.name)
                    .frame(minWidth: 80, alignment: .leading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
