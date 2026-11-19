import AlocirCore
import AppKit
import SwiftUI

/// Draws every tile in one Canvas. Depends only on the layout, the palette,
/// the folder tints and the search state, so hover and selection (separate
/// overlays) never redraw it.
struct TreemapCanvas: View, Equatable {
    let layout: TreemapLayout
    /// Changes whenever `layout` is recomputed.
    let layoutID: Int
    let palette: Palette
    /// The kind of file that takes the most space in each folder
    /// (`FolderKinds`), which tints the folder.
    let folderKinds: [ObjectIdentifier: FileKind]
    /// Changes whenever `folderKinds` is recomputed.
    let folderKindsID: Int
    let showLabels: Bool
    let searchActive: Bool
    /// Changes when the search result changes.
    let searchID: Int
    let isDark: Bool
    let increasedContrast: Bool

    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.layoutID == b.layoutID && a.palette == b.palette && a.folderKindsID == b.folderKindsID
            && a.showLabels == b.showLabels && a.searchActive == b.searchActive && a.searchID == b.searchID
            && a.isDark == b.isDark && a.increasedContrast == b.increasedContrast
    }

    /// Tiles with a gloss gradient, and with labels, are capped.
    static let maxGlossTiles = 400
    static let maxLabels = 400

    var body: some View {
        Canvas(opaque: false, rendersAsynchronously: false) { context, _ in
            draw(in: &context)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Treemap")
        .accessibilityChildren {
            // At least the top-level tiles, by name and size.
            ForEach(Array(layout.tiles.prefix(200).enumerated().filter { $0.element.depth == 0 }), id: \.offset) { _, tile in
                Rectangle()
                    .frame(width: tile.rect.width, height: tile.rect.height)
                    .position(x: tile.rect.midX, y: tile.rect.midY)
                    .accessibilityLabel(Text(verbatim: tile.node.name))
                    .accessibilityValue(Text(Formatting.size(tile.node.size)))
                    .accessibilityAddTraits(.isButton)
            }
        }
    }

    private enum Fill: Hashable {
        case kind(FileKind)
        /// A folder drawn as a frame around its children, or solid when its
        /// children are too small to draw.
        case folder(rgb: UInt32, frame: Bool)
    }

    private func color(_ fill: Fill) -> Color {
        switch fill {
        case .kind(let kind): palette.color(for: kind)
        case .folder(let rgb, let frame): Color(rgb: rgb).opacity(frame ? (isDark ? 0.40 : 0.30) : (isDark ? 0.92 : 0.86))
        }
    }

    /// 0–3 from a folder's name, stable between launches (unlike `hashValue`).
    private static func shade(of name: String) -> UInt8 {
        var hash: UInt32 = 2_166_136_261
        for byte in name.utf8 { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
        return UInt8(truncatingIfNeeded: hash >> 7) & 3
    }

    private func folderRGB(_ node: FileNode) -> UInt32 {
        palette.folderRGB(holding: folderKinds[ObjectIdentifier(node)], shade: Self.shade(of: node.name))
    }

    private func draw(in context: inout GraphicsContext) {
        // One Path per fill colour (and dimmed state), each filled once.
        var paths: [Fill: Path] = [:]
        var dimmedPaths: [Fill: Path] = [:]
        var frames = Path()
        var gloss: [CGRect] = []
        var labels: [(rect: CGRect, tile: Tile, header: Bool, rgb: UInt32?)] = []

        for tile in layout.tiles {
            let rect = tile.rect.insetBy(dx: 0.75, dy: 0.75)
            guard rect.width >= 0.5, rect.height >= 0.5 else { continue }
            let node = tile.node
            let rgb = node.isDirectory ? folderRGB(node) : nil
            let fill: Fill = rgb.map { .folder(rgb: $0, frame: tile.showsChildren) } ?? .kind(node.kind)
            let dimmed = searchActive && node.searchMark == 0
            let radius = min(rect.width, rect.height) > 12 ? 4.0 : 0
            let shape = radius > 0 ? Path(roundedRect: rect, cornerRadius: radius, style: .continuous) : Path(rect)
            if dimmed {
                dimmedPaths[fill, default: Path()].addPath(shape)
            } else {
                paths[fill, default: Path()].addPath(shape)
            }
            if tile.showsChildren { frames.addPath(shape) }
            // Classic gel goes on every tile big enough to show it; the modern
            // gloss only on the bigger ones.
            let minGloss: CGFloat = palette.isClassic ? 12 : 36
            if !dimmed, !tile.showsChildren, gloss.count < Self.maxGlossTiles, rect.width > minGloss, rect.height > minGloss {
                gloss.append(rect)
            }
            if showLabels, labels.count < Self.maxLabels {
                if tile.showsChildren, rect.width >= 40 {
                    labels.append((rect, tile, true, rgb))
                } else if !tile.showsChildren, rect.width >= 40, rect.height >= 22 {
                    labels.append((rect, tile, false, rgb))
                }
            }
        }

        // Folder frames are translucent and sit under their children, so they
        // go first; painted after, they would wash out the tiles inside.
        func isFrame(_ fill: Fill) -> Bool {
            if case .folder(_, frame: true) = fill { return true }
            return false
        }
        for pass in [true, false] {
            for (fill, path) in paths where isFrame(fill) == pass {
                context.fill(path, with: .color(color(fill)))
            }
            for (fill, path) in dimmedPaths where isFrame(fill) == pass {
                context.fill(path, with: .color(color(fill).opacity(0.22)))
            }
        }

        for rect in gloss {
            let shape = Path(roundedRect: rect, cornerRadius: 4, style: .continuous)
            if palette.isClassic {
                drawGel(shape, in: rect, context: &context)
            } else {
                // Soft top-down gloss on the bigger tiles.
                context.fill(shape, with: .linearGradient(
                    Gradient(colors: [.white.opacity(isDark ? 0.14 : 0.22), .white.opacity(0)]),
                    startPoint: CGPoint(x: rect.midX, y: rect.minY),
                    endPoint: CGPoint(x: rect.midX, y: rect.minY + min(rect.height, 120))))
            }
        }
        // Folder frames get a hairline so nesting reads at a glance.
        let frameStroke = (isDark ? Color.white : Color.black).opacity(increasedContrast ? 0.5 : 0.16)
        context.stroke(frames, with: .color(frameStroke), lineWidth: increasedContrast ? 1.5 : 1)

        for label in labels {
            if label.header {
                drawHeader(label.tile, in: label.rect, context: &context)
            } else {
                drawTileLabel(label.tile, in: label.rect, folderRGB: label.rgb, context: &context)
            }
        }
    }

    /// Classic gel: a bright highlight across the top that ends at a hard
    /// edge, a soft glow coming back up from the bottom, and a thin dark
    /// outline. The highlight is a band, not half the tile, so big tiles
    /// don't look bloated.
    private func drawGel(_ shape: Path, in rect: CGRect, context: inout GraphicsContext) {
        let band = min(rect.height * 0.5, 36)
        context.fill(shape, with: .linearGradient(
            Gradient(stops: [
                .init(color: .white.opacity(isDark ? 0.42 : 0.58), location: 0),
                .init(color: .white.opacity(isDark ? 0.10 : 0.16), location: 0.98),
                .init(color: .clear, location: 1),
            ]),
            startPoint: CGPoint(x: rect.midX, y: rect.minY),
            endPoint: CGPoint(x: rect.midX, y: rect.minY + band)))
        let glow = min(rect.height * 0.35, 28)
        context.fill(shape, with: .linearGradient(
            Gradient(colors: [.clear, .white.opacity(isDark ? 0.12 : 0.22)]),
            startPoint: CGPoint(x: rect.midX, y: rect.maxY - glow),
            endPoint: CGPoint(x: rect.midX, y: rect.maxY)))
        context.stroke(shape, with: .color(.black.opacity(isDark ? 0.45 : 0.25)), lineWidth: 0.75)
    }

    // MARK: Labels

    private var fitter: LabelFitter { .shared }

    /// A nested folder's header strip: its name, then its size. The name is
    /// shortened before the size is dropped; nothing is drawn rather than a
    /// cut-off size.
    private func drawHeader(_ tile: Tile, in rect: CGRect, context: inout GraphicsContext) {
        let node = tile.node
        let dimmed = searchActive && node.searchMark == 0
        let color = (isDark ? Color.white : Color.black).opacity(dimmed ? 0.35 : 0.9)
        let fontSize: CGFloat = 11
        let padding: CGFloat = 6
        let gap: CGFloat = 6
        let available = rect.width - padding * 2
        let size = Formatting.size(node.size)
        let sizeWidth = fitter.width(size, size: fontSize, weight: .regular, monospacedDigits: true)

        var name: String?
        var showSize = false
        if available - sizeWidth - gap > 0,
            let fitted = fitter.fit(
                node.name, maxWidth: available - sizeWidth - gap, size: fontSize, weight: .semibold,
                keepingExtension: false)
        {
            name = fitted
            showSize = true
        } else {
            name = fitter.fit(node.name, maxWidth: available, size: fontSize, weight: .semibold, keepingExtension: false)
        }
        guard let name else { return }

        let y = rect.minY + layout.options.headerHeight / 2
        let nameWidth = fitter.width(name, size: fontSize, weight: .semibold)
        context.drawLayer { layer in
            layer.clip(to: Path(rect))
            layer.draw(
                Text(verbatim: name).font(.system(size: fontSize, weight: .semibold)).foregroundStyle(color),
                at: CGPoint(x: rect.minX + padding, y: y), anchor: .leading)
            if showSize {
                layer.draw(
                    Text(verbatim: size).font(.system(size: fontSize).monospacedDigit()).foregroundStyle(color.opacity(0.65)),
                    at: CGPoint(x: rect.minX + padding + nameWidth + gap, y: y), anchor: .leading)
            }
        }
    }

    /// A tile's name, centred, on one line or two when it is tall enough,
    /// and its size below when there is room. Solid folders get a small
    /// folder symbol, since they are tinted like files.
    private func drawTileLabel(_ tile: Tile, in rect: CGRect, folderRGB: UInt32?, context: inout GraphicsContext) {
        let node = tile.node
        let dimmed = searchActive && node.searchMark == 0
        let base: Color = folderRGB.map { Palette.labelColor(on: $0) } ?? palette.labelColor(for: node.kind)
        let color = base.opacity(dimmed ? 0.35 : 1)
        let fontSize = min(max(rect.width / 11, 10), 15)
        let lineHeight = (fontSize * 1.25).rounded(.up)
        let sizeFontSize = fontSize - 2
        let sizeLineHeight = (sizeFontSize * 1.3).rounded(.up)
        let padding: CGFloat = 5
        let available = rect.width - padding * 2
        let isFolder = node.isDirectory
        // Room taken by the folder symbol and a space before the name.
        let iconWidth: CGFloat = isFolder ? (fontSize * 1.25).rounded(.up) : 0

        var lines: [String] = []
        if let whole = fitter.fit(
            node.name, maxWidth: available - iconWidth, size: fontSize, weight: .medium, keepingExtension: !isFolder),
            whole == node.name
        {
            lines = [whole]
        } else if rect.height >= lineHeight * 2 + 4,
            let (first, second) = fitter.fitTwoLines(
                node.name, maxWidth: available - iconWidth, size: fontSize, weight: .medium, keepingExtension: !isFolder)
        {
            lines = [first, second]
        } else if let shortened = fitter.fit(
            node.name, maxWidth: available - iconWidth, size: fontSize, weight: .medium, keepingExtension: !isFolder)
        {
            lines = [shortened]
        }
        guard !lines.isEmpty else { return }

        let size = Formatting.size(node.size)
        let showSize =
            rect.height >= lineHeight * CGFloat(lines.count) + sizeLineHeight + 4
            && fitter.width(size, size: sizeFontSize, weight: .regular, monospacedDigits: true) <= available
        let blockHeight = lineHeight * CGFloat(lines.count) + (showSize ? sizeLineHeight : 0)
        var y = rect.midY - blockHeight / 2 + lineHeight / 2

        context.drawLayer { layer in
            layer.clip(to: Path(rect))
            for (index, line) in lines.enumerated() {
                var text = Text(verbatim: line).font(.system(size: fontSize, weight: .medium))
                if isFolder && index == 0 {
                    let icon = Text(Image(systemName: "folder.fill")).font(.system(size: fontSize * 0.8))
                    text = Text("\(icon) \(text)")
                }
                layer.draw(text.foregroundStyle(color), at: CGPoint(x: rect.midX, y: y), anchor: .center)
                y += lineHeight
            }
            if showSize {
                y += (sizeLineHeight - lineHeight) / 2
                layer.draw(
                    Text(verbatim: size).font(.system(size: sizeFontSize).monospacedDigit()).foregroundStyle(color.opacity(0.8)),
                    at: CGPoint(x: rect.midX, y: y), anchor: .center)
            }
        }
    }
}
