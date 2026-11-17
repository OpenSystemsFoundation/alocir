import AlocirCore
import SwiftUI

/// The trailing inspector: the selected item, what the focused folder holds
/// by kind (which doubles as the colour legend), and its largest items or
/// the search results.
struct InspectorView: View {
    let session: Session
    let tree: LiveTree
    @Environment(AppSettings.self) private var settings
    @State private var summary: FolderSummary?

    private struct SummaryKey: Equatable {
        var version: UInt64
        var focus: ObjectIdentifier
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                ItemCard(session: session, tree: tree, node: tree.selection ?? tree.focus)
                if let summary {
                    KindBreakdown(summary: summary, total: tree.focus.size, palette: settings.palette)
                }
                if let result = session.search.result, session.search.query != nil {
                    NodeList(
                        title: "\(Formatting.count(UInt64(result.count))) matches · \(Formatting.size(result.totalSize))",
                        nodes: Array(result.matches.prefix(200)), session: session, tree: tree)
                } else if session.search.query != nil {
                    ProgressView("Searching…")
                        .controlSize(.small)
                } else if let summary {
                    NodeList(title: "Largest Files", nodes: summary.largestFiles, session: session, tree: tree)
                }
            }
            .padding(16)
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .task(id: SummaryKey(version: tree.version, focus: ObjectIdentifier(tree.focus))) {
            summary = FolderSummary(of: tree.focus)
        }
    }
}

private struct ItemCard: View {
    let session: Session
    let tree: LiveTree
    let node: FileNode
    @Environment(AppSettings.self) private var settings

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: node.isDirectory ? "folder.fill" : node.kind.symbol)
                    .font(.system(size: 26))
                    .foregroundStyle(node.isDirectory ? settings.palette.folderTint : settings.palette.color(for: node.kind))
                    .frame(width: 44, height: 44)
                    .glassEffect(.regular, in: .rect(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 3) {
                    Text(node === tree.root ? displayName : node.name)
                        .font(.headline)
                        .lineLimit(2)
                        .truncationMode(.middle)
                    Text(Formatting.size(node.size))
                        .font(.title3.weight(.semibold))
                        .monospacedDigit()
                    if let parent = node.parent {
                        Text("\(Formatting.percent(node.size, of: parent.size)) of “\(parent === tree.root ? displayName : parent.name)”")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Text(node.path)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .truncationMode(.middle)
                .textSelection(.enabled)
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    Button("Show in Finder", systemImage: "folder") { session.revealInFinder(node) }
                    Button("Quick Look", systemImage: "eye") { session.quickLook(node) }
                    Button("Move to Trash", systemImage: "trash", role: .destructive) { session.moveToTrash(node) }
                        .disabled(node === tree.root)
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.glass)
                .controlSize(.large)
            }
        }
    }

    private var displayName: String {
        tree.root.name == "/" ? String(localized: "Startup Disk") : (tree.root.name as NSString).lastPathComponent
    }
}

private struct KindBreakdown: View {
    let summary: FolderSummary
    let total: UInt64
    let palette: Palette

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("By Kind")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            // A stacked bar of the kinds, then one row per kind.
            GeometryReader { proxy in
                HStack(spacing: 1.5) {
                    ForEach(summary.kinds, id: \.kind) { entry in
                        Rectangle()
                            .fill(palette.color(for: entry.kind))
                            .frame(width: max(2, proxy.size.width * share(entry.bytes)))
                    }
                }
            }
            .frame(height: 10)
            .clipShape(.capsule)
            ForEach(summary.kinds, id: \.kind) { entry in
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(palette.color(for: entry.kind))
                        .frame(width: 12, height: 12)
                    Text(entry.kind.label)
                    Spacer(minLength: 8)
                    Text(Formatting.size(entry.bytes))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func share(_ bytes: UInt64) -> CGFloat {
        let sum = summary.kinds.reduce(0) { $0 + $1.bytes }
        return sum == 0 ? 0 : CGFloat(Double(bytes) / Double(sum))
    }
}

private struct NodeList: View {
    let title: String
    let nodes: [FileNode]
    let session: Session
    let tree: LiveTree
    @Environment(AppSettings.self) private var settings

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(nodes) { node in
                Button {
                    select(node)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: node.isDirectory ? "folder.fill" : node.kind.symbol)
                            .foregroundStyle(node.isDirectory ? settings.palette.folderTint : settings.palette.color(for: node.kind))
                            .frame(width: 18)
                        Text(node.name)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 8)
                        Text(Formatting.size(node.size))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .font(.callout)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contextMenu { FileMenuItems(session: session, node: node) }
            }
        }
    }

    /// Shows the item: focus its folder and select it.
    private func select(_ node: FileNode) {
        if let parent = node.parent, parent !== tree.focus, !isInsideFocus(node) {
            session.go(to: parent)
        }
        tree.selection = node
    }

    private func isInsideFocus(_ node: FileNode) -> Bool {
        var current = node.parent
        while let c = current {
            if c === tree.focus { return true }
            current = c.parent
        }
        return false
    }
}
