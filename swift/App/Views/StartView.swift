import AlocirCore
import SwiftUI

/// The start screen: a centred hero on a full-window background, the folder
/// buttons, and recent folders. The whole window is a drop target.
struct StartView: View {
    let session: Session
    @Environment(RecentFolders.self) private var recents
    @State private var dropTargeted = false

    var body: some View {
        ZStack {
            StartBackground()
                .ignoresSafeArea()
            VStack(spacing: 26) {
                hero
                buttons
                if !recents.entries.isEmpty {
                    RecentList(session: session, entries: recents.entries)
                        .frame(maxWidth: 520)
                }
                Label("Whole-disk scans skip protected folders until you allow Full Disk Access in System Settings.", systemImage: "lock.shield")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
            }
            .padding(40)
            if dropTargeted {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
                    .padding(14)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: \.hasDirectoryPath) ?? urls.first else { return false }
            session.open(url)
            return true
        } isTargeted: { dropTargeted = $0 }
        .navigationTitle("Alocir")
    }

    private var hero: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 112, height: 112)
                .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
                .accessibilityHidden(true)
            Text("Alocir")
                .font(.system(size: 34, weight: .bold, design: .rounded))
            Text("See what fills your disk, at a glance.")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
    }

    private var buttons: some View {
        GlassEffectContainer(spacing: 14) {
            VStack(spacing: 14) {
                Button {
                    session.chooseFolder()
                } label: {
                    Label("Choose Folder…", systemImage: "folder.badge.plus")
                        .padding(.horizontal, 10)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.extraLarge)
                .keyboardShortcut("o")
                HStack(spacing: 12) {
                    Button {
                        session.chooseFolder(startingAt: FileManager.default.homeDirectoryForCurrentUser)
                    } label: {
                        Label("Home", systemImage: "house")
                    }
                    Button {
                        session.chooseFolder(startingAt: URL(filePath: "/"))
                    } label: {
                        Label("Startup Disk", systemImage: "internaldrive")
                    }
                }
                .buttonStyle(.glass)
                .controlSize(.large)
            }
        }
    }
}

/// A soft, slowly varying colour field behind the start screen.
struct StartBackground: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(AppSettings.self) private var settings

    var body: some View {
        let p = settings.palette
        let dark = colorScheme == .dark
        let base: Color = dark ? Color(rgb: 0x101218) : Color(rgb: 0xF4F5F8)
        MeshGradient(
            width: 3, height: 3,
            points: [
                [0, 0], [0.5, 0], [1, 0],
                [0, 0.5], [0.55, 0.45], [1, 0.5],
                [0, 1], [0.5, 1], [1, 1],
            ],
            colors: [
                p.color(for: .video).opacity(dark ? 0.55 : 0.40), base, p.color(for: .image).opacity(dark ? 0.50 : 0.35),
                base, base, base,
                p.color(for: .document).opacity(dark ? 0.50 : 0.35), base, p.color(for: .audio).opacity(dark ? 0.55 : 0.40),
            ]
        )
        .background(base)
    }
}

private struct RecentList: View {
    let session: Session
    let entries: [RecentFolders.Entry]
    @Environment(RecentFolders.self) private var recents

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recent")
                .font(.headline)
                .foregroundStyle(.secondary)
                .padding(.leading, 6)
            VStack(spacing: 0) {
                ForEach(entries) { entry in
                    Button {
                        session.open(entry)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: entry.path == "/" ? "internaldrive.fill" : (entry.path.hasPrefix("/Volumes/") ? "externaldrive.fill" : "folder.fill"))
                                .font(.title3)
                                .foregroundStyle(.tint)
                                .frame(width: 26)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.name)
                                    .fontWeight(.medium)
                                Text(entry.path)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer(minLength: 12)
                            VStack(alignment: .trailing, spacing: 2) {
                                if let size = entry.lastSize {
                                    Text(Formatting.size(size))
                                        .monospacedDigit()
                                }
                                if let date = entry.lastScan {
                                    Text(date, format: .relative(presentation: .named))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Remove from Recents", systemImage: "minus.circle") { recents.remove(entry) }
                    }
                    if entry != entries.last {
                        Divider().padding(.leading, 52)
                    }
                }
            }
            .glassEffect(.regular, in: .rect(cornerRadius: 18))
        }
    }
}
