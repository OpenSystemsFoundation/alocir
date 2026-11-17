import AlocirCore
import QuickLook
import SwiftUI

/// The treemap screen: the map fills the window edge to edge and runs under
/// the toolbar, with a floating status capsule and the inspector.
struct MapView: View {
    @Bindable var session: Session
    let tree: LiveTree
    @Environment(AppSettings.self) private var settings
    @Environment(\.openWindow) private var openWindow
    @FocusState private var searchFocused: Bool

    var body: some View {
        @Bindable var settings = settings
        // The status bar sits below the map, not over it, so it never covers
        // tiles.
        VStack(spacing: 0) {
            TreemapArea(session: session, tree: tree)
            StatusBar(session: session, tree: tree)
        }
            .navigationTitle(tree.focus === tree.root ? displayName(of: tree.root) : tree.focus.name)
            .navigationSubtitle(Formatting.size(tree.focus.size))
            .toolbar { toolbar }
            .searchable(text: $session.searchText, placement: .toolbar, prompt: Text("Name, .ext, >100mb"))
            .searchFocused($searchFocused)
            .inspector(isPresented: $settings.showInspector) {
                InspectorView(session: session, tree: tree)
                    .inspectorColumnWidth(min: 250, ideal: 290, max: 420)
            }
            .quickLookPreview($session.quickLookURL)
            .sheet(item: $session.renaming) { node in
                RenameSheet(session: session, node: node)
            }
            .onChange(of: tree.version) { session.search.treeDidChange(tree) }
            .focusedSceneValue(\FocusedValues.focusSearch, FocusSearchAction { searchFocused = true })
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button {
                session.zoomOut()
            } label: {
                Label("Enclosing Folder", systemImage: "chevron.up")
            }
            .help("Zoom out to the enclosing folder (⌘↑)")
            .disabled(tree.focus.parent == nil)
        }
        ToolbarItem(placement: .principal) {
            Breadcrumb(session: session, tree: tree)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                session.rescan()
            } label: {
                Label("Rescan", systemImage: "arrow.clockwise")
            }
            .help("Scan the folder again (⌘R)")
            Button {
                TabRequests.shared.scanFolderInNewTab(openWindow: openWindow)
            } label: {
                Label("New Scan", systemImage: "plus")
            }
            .help("Scan another folder in a new tab (⌥⌘O)")
            Button {
                settings.showInspector.toggle()
            } label: {
                Label("Inspector", systemImage: "sidebar.trailing")
            }
            .help("Show or hide the inspector (⌥⌘I)")
        }
    }

    private func displayName(of node: FileNode) -> String {
        node.name == "/" ? String(localized: "Startup Disk") : (node.name as NSString).lastPathComponent
    }
}

struct FocusSearchAction {
    let action: () -> Void
    func callAsFunction() { action() }
}

extension FocusedValues {
    @Entry var focusSearch: FocusSearchAction?
}

/// Breadcrumb of the focused folder's path, as the toolbar's principal item.
///
/// Deep paths don't fit, so it works like a jump bar: the scanned folder and
/// the focused one are always shown, the nearest folders above the focus
/// fill whatever room is left, and the rest fold into one "⋯" menu, in path
/// order. Each name is capped in width, so one long name can't crowd out the
/// others. On a very narrow toolbar the scanned folder folds into the menu
/// too.
struct Breadcrumb: View {
    let session: Session
    let tree: LiveTree

    /// Widest a single crumb gets before its name is shortened in the middle.
    private static let maxCrumbWidth: CGFloat = 150
    /// Toolbar text size, used to measure names.
    private static let fontSize: CGFloat = 13
    /// The most trail variants tried, longest first.
    private static let maxVariants = 10

    var body: some View {
        let chain = ancestors()
        // Folders between the scanned one and the focus.
        let middle = max(chain.count - 2, 0)
        let shownCounts = Array((0...min(middle, Self.maxVariants)).reversed())
        ViewThatFits(in: .horizontal) {
            ForEach(shownCounts, id: \.self) { shown in
                trail(chain, nearest: shown, keepRoot: true)
            }
            trail(chain, nearest: 0, keepRoot: false)
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: 560)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Path")
    }

    /// The scanned folder (unless `keepRoot` is false), a "⋯" menu for the
    /// folders left out, the `nearest` folders above the focus, and the focus.
    @ViewBuilder
    private func trail(_ chain: [FileNode], nearest: Int, keepRoot: Bool) -> some View {
        HStack(spacing: 2) {
            if chain.count == 1 {
                // At the scanned folder itself.
                crumb(chain[0], isRoot: true)
            } else {
                let firstShown = max(chain.count - 1 - nearest, 1)
                let hidden = Array(chain[(keepRoot ? 1 : 0)..<firstShown])
                if keepRoot {
                    crumb(chain[0], isRoot: true)
                }
                if !hidden.isEmpty {
                    if keepRoot { separator }
                    overflowMenu(hidden)
                }
                ForEach(Array(chain[firstShown...])) { node in
                    separator
                    crumb(node, isRoot: false)
                }
            }
        }
        .fixedSize()
    }

    private var separator: some View {
        Image(systemName: "chevron.compact.right")
            .foregroundStyle(.tertiary)
            .imageScale(.small)
    }

    private func crumb(_ node: FileNode, isRoot: Bool) -> some View {
        let isFocus = node === tree.focus
        let name = isRoot ? rootName : node.name
        let shown =
            LabelFitter.shared.fit(
                name, maxWidth: Self.maxCrumbWidth, size: Self.fontSize, weight: isFocus ? .semibold : .regular,
                keepingExtension: false) ?? name
        return Button {
            session.go(to: node)
        } label: {
            Text(verbatim: shown)
                .lineLimit(1)
                .fontWeight(isFocus ? .semibold : .regular)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(isFocus ? .primary : .secondary)
        .help(node.path)
    }

    /// The folders left out of the trail, top first, each one click away.
    private func overflowMenu(_ hidden: [FileNode]) -> some View {
        Menu {
            ForEach(hidden) { node in
                Button {
                    session.go(to: node)
                } label: {
                    Label {
                        Text(verbatim: node === tree.root ? rootName : node.name)
                    } icon: {
                        Image(systemName: node === tree.root ? "internaldrive" : "folder")
                    }
                }
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(Text("\(hidden.count) more folders"))
        .accessibilityLabel(Text("\(hidden.count) more folders"))
    }

    private var rootName: String {
        tree.root.name == "/" ? String(localized: "Startup Disk") : (tree.root.name as NSString).lastPathComponent
    }

    private func ancestors() -> [FileNode] {
        var chain: [FileNode] = []
        var node: FileNode? = tree.focus
        while let current = node {
            chain.append(current)
            node = current.parent
        }
        return chain.reversed()
    }
}

/// The map itself: layout, the canvas, overlays and input.
struct TreemapArea: View {
    let session: Session
    let tree: LiveTree
    @Environment(AppSettings.self) private var settings
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var layout: TreemapLayout?
    @State private var layoutID = 0
    @State private var size: CGSize = .zero
    @State private var zoomTransform = ZoomTransform.identity
    @State private var crossFade = 1.0
    /// Folder tints: the dominant kind of each folder below the focus.
    @State private var folderKinds: [ObjectIdentifier: FileKind] = [:]
    @State private var folderKindsID = 0
    @State private var folderKindsKey: FolderKindsKey?
    @State private var folderKindsVersion: UInt64 = 0
    @State private var folderKindsRefresh: Task<Void, Never>?

    struct LayoutKey: Equatable {
        var version: UInt64
        var focus: ObjectIdentifier
        var size: CGSize
        var depth: Int
    }

    /// What the folder tints were computed for.
    struct FolderKindsKey: Equatable {
        var focus: ObjectIdentifier
        var depth: Int
    }

    var body: some View {
        GeometryReader { proxy in
            let key = LayoutKey(
                version: tree.version, focus: ObjectIdentifier(tree.focus), size: proxy.size,
                depth: settings.nestingDepth)
            ZStack(alignment: .topLeading) {
                Rectangle().fill(.background)
                if let layout {
                    TreemapCanvas(
                        layout: layout, layoutID: layoutID, palette: settings.palette,
                        folderKinds: folderKinds, folderKindsID: folderKindsID,
                        showLabels: settings.showLabels, searchActive: session.search.query != nil,
                        searchID: searchID, isDark: colorScheme == .dark,
                        increasedContrast: contrast == .increased
                    )
                    .equatable()
                    SelectionOverlay(tree: tree, layout: layout, layoutID: layoutID)
                    InteractionLayer(session: session, tree: tree, layout: layout)
                }
            }
            .scaleEffect(x: zoomTransform.scale.width, y: zoomTransform.scale.height, anchor: .topLeading)
            .offset(x: zoomTransform.offset.x, y: zoomTransform.offset.y)
            .opacity(crossFade)
            .clipped()
            .onChange(of: key, initial: true) { _, newKey in
                relayout(key: newKey)
            }
        }
    }

    private var searchID: Int {
        var hasher = Hasher()
        hasher.combine(session.search.result?.count)
        hasher.combine(session.search.result?.totalSize)
        hasher.combine(session.search.query?.terms.count)
        hasher.combine(session.search.isSearching)
        return hasher.finalize()
    }

    private func relayout(key: LayoutKey) {
        var options = TreemapLayout.Options()
        options.maxDepth = key.depth
        let new = TreemapLayout(focus: tree.focus, bounds: CGRect(origin: .zero, size: key.size), options: options)
        layout = new
        layoutID &+= 1
        size = key.size
        updateFolderKinds(key)
        guard let zoom = session.zoom, key.size.width > 0, key.size.height > 0 else { return }
        session.zoomFinished()
        if reduceMotion {
            crossFade = 0
            withAnimation(.easeInOut(duration: 0.2)) { crossFade = 1 }
            return
        }
        switch zoom.direction {
        case .into:
            // The new map starts inside the tile it grows out of.
            zoomTransform = ZoomTransform(
                scale: CGSize(width: zoom.rect.width / key.size.width, height: zoom.rect.height / key.size.height),
                offset: zoom.rect.origin)
        case .outOf:
            // The new map starts zoomed in on where the old folder sits.
            guard let index = tree.selection.flatMap({ new.index(of: $0) }) else { return }
            let rect = new.tiles[index].rect
            guard rect.width > 0, rect.height > 0 else { return }
            let scale = CGSize(width: key.size.width / rect.width, height: key.size.height / rect.height)
            zoomTransform = ZoomTransform(scale: scale, offset: CGPoint(x: -rect.minX * scale.width, y: -rect.minY * scale.height))
        }
        withAnimation(.smooth(duration: 0.35)) { zoomTransform = .identity }
    }

    /// Folder tints read the whole subtree (about 17 ms for half a million
    /// items), so they are computed right away only when the focus or depth
    /// changes. While files change they keep their colours and refresh a
    /// second later, so a burst of changes costs one pass. Resizing never
    /// recomputes them.
    private func updateFolderKinds(_ key: LayoutKey) {
        let wanted = FolderKindsKey(focus: key.focus, depth: key.depth)
        if wanted != folderKindsKey {
            folderKindsRefresh?.cancel()
            folderKindsRefresh = nil
            computeFolderKinds(wanted, version: key.version)
            return
        }
        guard key.version != folderKindsVersion, folderKindsRefresh == nil else { return }
        folderKindsRefresh = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            folderKindsRefresh = nil
            computeFolderKinds(
                FolderKindsKey(focus: ObjectIdentifier(tree.focus), depth: settings.nestingDepth), version: tree.version)
        }
    }

    private func computeFolderKinds(_ key: FolderKindsKey, version: UInt64) {
        folderKinds = FolderKinds.dominantKinds(below: tree.focus, levels: key.depth)
        folderKindsKey = key
        folderKindsVersion = version
        folderKindsID &+= 1
    }
}

struct ZoomTransform: Equatable {
    var scale: CGSize
    var offset: CGPoint
    static let identity = ZoomTransform(scale: CGSize(width: 1, height: 1), offset: .zero)
}

/// The selected tile's outline. A separate view, so selecting never
/// redraws the canvas.
struct SelectionOverlay: View {
    let tree: LiveTree
    let layout: TreemapLayout
    let layoutID: Int

    var body: some View {
        if let selection = tree.selection, let index = layout.index(of: selection) {
            let rect = layout.tiles[index].rect.insetBy(dx: 0.5, dy: 0.5)
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(Color.accentColor, lineWidth: 3)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.accentColor.opacity(0.12)))
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.minX, y: rect.minY)
                .allowsHitTesting(false)
        }
    }
}

/// Pointer, click and keyboard input over the map, plus the hover outline.
struct InteractionLayer: View {
    let session: Session
    let tree: LiveTree
    let layout: TreemapLayout
    @State private var hoveredIndex: Int?
    @FocusState private var focused: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
                .contentShape(Rectangle())
            if let hoveredIndex, hoveredIndex < layout.tiles.count {
                let rect = layout.tiles[hoveredIndex].rect.insetBy(dx: 0.5, dy: 0.5)
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(.white.opacity(0.9), lineWidth: 2)
                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(.white.opacity(0.10)))
                    .shadow(color: .black.opacity(0.25), radius: 3)
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY)
                    .allowsHitTesting(false)
            }
        }
        .onContinuousHover(coordinateSpace: .local) { phase in
            switch phase {
            case .active(let point):
                let index = layout.hitTest(point)
                if index != hoveredIndex {
                    hoveredIndex = index
                    session.hovered = index.map { layout.tiles[$0].node }
                }
            case .ended:
                hoveredIndex = nil
                session.hovered = nil
            }
        }
        .gesture(
            SpatialTapGesture(count: 2).onEnded { value in doubleClick(at: value.location) }
                .exclusively(before: SpatialTapGesture(count: 1).onEnded { value in click(at: value.location) })
        )
        .contextMenu {
            if let node = session.hovered ?? tree.selection {
                FileMenuItems(session: session, node: node)
            }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true }
        .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
            arrow(press.key, modifiers: press.modifiers)
        }
        .onKeyPress(.space) {
            guard let node = tree.selection else { return .ignored }
            session.quickLook(node)
            return .handled
        }
        .onKeyPress(.return) {
            guard let node = tree.selection, node !== tree.root else { return .ignored }
            session.renaming = node
            return .handled
        }
        .onKeyPress(.escape) {
            if tree.selection != nil {
                tree.selection = nil
            } else if !session.searchText.isEmpty {
                session.searchText = ""
            } else {
                return .ignored
            }
            return .handled
        }
        .onKeyPress(.delete) {
            session.zoomOut()
            return .handled
        }
    }

    private func click(at point: CGPoint) {
        focused = true
        tree.selection = layout.hitTest(point).map { layout.tiles[$0].node }
    }

    private func doubleClick(at point: CGPoint) {
        guard let index = layout.hitTest(point) else { return }
        let tile = layout.tiles[index]
        if tile.node.isDirectory {
            // Zoom into the folder under the pointer, from its own tile.
            session.zoom(into: tile.node, fromRect: tile.rect)
        } else {
            tree.selection = tile.node
            session.quickLook(tile.node)
        }
    }

    private func arrow(_ key: KeyEquivalent, modifiers: EventModifiers) -> KeyPress.Result {
        if modifiers.contains(.option) {
            // ⌥↑ enclosing folder, ⌥↓ largest child.
            guard let selection = tree.selection, let index = layout.index(of: selection) else { return .ignored }
            if key == .upArrow, let parent = layout.parent(of: index) {
                tree.selection = layout.tiles[parent].node
            } else if key == .downArrow, let child = layout.firstChild(of: index) {
                tree.selection = layout.tiles[child].node
            }
            return .handled
        }
        guard let selection = tree.selection, let index = layout.index(of: selection) else {
            // Nothing selected yet: start with the largest tile.
            if !layout.tiles.isEmpty { tree.selection = layout.tiles[0].node }
            return .handled
        }
        let direction: TreemapLayout.Direction =
            switch key {
            case .leftArrow: .left
            case .rightArrow: .right
            case .upArrow: .up
            default: .down
            }
        if let next = layout.move(from: index, direction: direction) {
            tree.selection = layout.tiles[next].node
        }
        return .handled
    }
}

/// The status bar below the map: the hovered item (or an error, for six
/// seconds) on the left, and the scan's totals on the right, always visible.
struct StatusBar: View {
    let session: Session
    let tree: LiveTree

    var body: some View {
        HStack(spacing: 10) {
            leading
                .frame(maxWidth: .infinity, alignment: .leading)
            totals
                .layoutPriority(1)
        }
        .font(.callout)
        .lineLimit(1)
        .padding(.horizontal, 14)
        .frame(height: 30)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var leading: some View {
        if let notice = session.notice {
            Label(notice.message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        } else if let node = session.hovered {
            HStack(spacing: 8) {
                Image(systemName: node.isDirectory ? "folder.fill" : node.kind.symbol)
                    .foregroundStyle(.secondary)
                Text(verbatim: node.name)
                    .fontWeight(.medium)
                    .truncationMode(.middle)
                Text(Formatting.size(node.size))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .fixedSize()
                Text(Formatting.percent(node.size, of: tree.focus.size))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .fixedSize()
            }
        } else {
            Text(verbatim: tree.scanPath)
                .foregroundStyle(.secondary)
                .truncationMode(.head)
        }
    }

    private var totals: some View {
        HStack(spacing: 10) {
            Label {
                Text(Formatting.size(tree.root.size)).monospacedDigit()
            } icon: {
                Image(systemName: "internaldrive").foregroundStyle(.secondary)
            }
            if let items = session.lastScanItems {
                Text("\(Formatting.count(items)) items")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            if let duration = session.lastScanDuration {
                Text("Scanned in \(Formatting.duration(duration))")
                    .foregroundStyle(.secondary)
            }
        }
        .fixedSize()
    }
}

extension FileNode: @retroactive Identifiable {}
