import AlocirCore
import SwiftUI

/// The scanning screen: folder name, three live figures in glass cards, the
/// current path, progress and Cancel.
struct ScanningView: View {
    let session: Session
    let scan: Session.Scan

    var body: some View {
        ZStack {
            StartBackground()
                .ignoresSafeArea()
            TimelineView(.periodic(from: .now, by: 0.1)) { context in
                content(now: context.date)
            }
            .padding(40)
        }
        .navigationTitle(name)
    }

    private var name: String {
        let path = scan.url.path(percentEncoded: false)
        return path == "/" ? String(localized: "Startup Disk") : scan.url.lastPathComponent
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        let items = scan.progress.itemsScanned
        let bytes = scan.progress.bytesScanned
        VStack(spacing: 28) {
            VStack(spacing: 8) {
                Image(systemName: scan.volumeUsedBytes == nil ? "folder.fill" : "internaldrive.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.tint)
                    .symbolEffect(.pulse, options: .repeating)
                Text("Scanning “\(name)”")
                    .font(.title2.weight(.semibold))
            }
            GlassEffectContainer(spacing: 14) {
                HStack(spacing: 14) {
                    StatCard(title: "Items", value: Formatting.count(items), symbol: "doc.on.doc")
                    StatCard(title: "Size", value: Formatting.size(bytes), symbol: "chart.pie")
                    StatCard(title: "Elapsed", value: Formatting.duration(seconds: now.timeIntervalSince(scan.started)), symbol: "clock")
                }
            }
            VStack(spacing: 10) {
                if let used = scan.volumeUsedBytes, used > 0 {
                    ProgressView(value: min(Double(bytes) / Double(used), 1))
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                }
                Text(scan.progress.currentPath)
                    .font(.caption.monospacedDigit().monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: 520)
            Button("Cancel", role: .cancel) { session.cancelScan() }
                .buttonStyle(.glass)
                .controlSize(.large)
                .keyboardShortcut(.cancelAction)
        }
    }
}

private struct StatCard: View {
    let title: LocalizedStringKey
    let value: String
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.title, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .contentTransition(.numericText())
        }
        .frame(width: 150, alignment: .leading)
        .padding(16)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
        .accessibilityElement(children: .combine)
    }
}
