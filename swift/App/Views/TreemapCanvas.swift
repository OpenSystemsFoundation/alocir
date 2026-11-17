import AlocirCore
import SwiftUI

/// Draws every tile in one Canvas. Depends only on the layout, the palette
/// and the search state, so hover and selection (separate overlays) never
/// redraw it.
struct TreemapCanvas: View, Equatable {
    let layout: TreemapLayout
    /// Changes whenever `layout` is recomputed.
    let layoutID: Int
    let palette: Palette
    let showLabels: Bool
    let searchActive: Bool
    /// Changes when the search result changes.
    let searchID: Int
    let isDark: Bool
    let increasedContrast: Bool

    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.layoutID == b.layoutID && a.palette == b.palette && a.showLabels == b.showLabels
            && a.searchActive == b.searchActive && a.searchID == b.searchID && a.isDark == b.isDark
            && a.increasedContrast == b.increasedContrast
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
                    .accessibilityLabel(Text(tile.node.name))
                    .accessibilityValue(Text(Formatting.size(tile.node.size)))
                    .accessibilityAddTraits(.isButton)
            }
        }
    }

    private enum Fill: Hashable {
        case kind(FileKind)
        case folderFrame
        case folderSolid
    }

    private func color(_ fill: Fill) -> Color {
        switch fill {
        case .kind(let kind): palette.color(for: kind)
        case .folderFrame: palette.folderTint.opacity(isDark ? 0.42 : 0.30)
        case .folderSolid: palette.folderTint.opacity(isDark ? 0.85 : 0.70)
        }
    }

    private func draw(in context: inout GraphicsContext) {
        // One Path per fill colour (and dimmed state), each filled once.
        var paths: [Fill: Path] = [:]
        var dimmedPaths: [Fill: Path] = [:]
        var frames = Path()
        var gloss: [CGRect] = []
        var labels: [(rect: CGRect, tile: Tile, header: Bool)] = []

        for tile in layout.tiles {
            let rect = tile.rect.insetBy(dx: 0.75, dy: 0.75)
            guard rect.width >= 0.5, rect.height >= 0.5 else { continue }
            let node = tile.node
            let fill: Fill = node.isDirectory ? (tile.showsChildren ? .folderFrame : .folderSolid) : .kind(node.kind)
            let dimmed = searchActive && node.searchMark == 0
            let radius = min(rect.width, rect.height) > 12 ? 4.0 : 0
            let shape = radius > 0 ? Path(roundedRect: rect, cornerRadius: radius, style: .continuous) : Path(rect)
            if dimmed {
                dimmedPaths[fill, default: Path()].addPath(shape)
            } else {
                paths[fill, default: Path()].addPath(shape)
            }
            if tile.showsChildren { frames.addPath(shape) }
            if !dimmed, !tile.showsChildren, gloss.count < Self.maxGlossTiles, rect.width > 36, rect.height > 36 {
                gloss.append(rect)
            }
            if showLabels, labels.count < Self.maxLabels {
                if tile.showsChildren, rect.width >= 40 {
                    labels.append((rect, tile, true))
                } else if !tile.showsChildren, rect.width >= 44, rect.height >= 26 {
                    labels.append((rect, tile, false))
                }
            }
        }

        for (fill, path) in paths { context.fill(path, with: .color(color(fill))) }
        for (fill, path) in dimmedPaths { context.fill(path, with: .color(color(fill).opacity(0.22))) }

        // Soft top-down gloss on the bigger tiles.
        for rect in gloss {
            let shape = Path(roundedRect: rect, cornerRadius: 4, style: .continuous)
            context.fill(shape, with: .linearGradient(
                Gradient(colors: [.white.opacity(isDark ? 0.14 : 0.22), .white.opacity(0)]),
                startPoint: CGPoint(x: rect.midX, y: rect.minY),
                endPoint: CGPoint(x: rect.midX, y: rect.minY + min(rect.height, 120))))
        }
        // Folder frames get a hairline so nesting reads at a glance.
        let frameStroke = (isDark ? Color.white : Color.black).opacity(increasedContrast ? 0.5 : 0.16)
        context.stroke(frames, with: .color(frameStroke), lineWidth: increasedContrast ? 1.5 : 1)

        for label in labels { drawLabel(label.tile, in: label.rect, header: label.header, context: &context) }
    }

    private func drawLabel(_ tile: Tile, in rect: CGRect, header: Bool, context: inout GraphicsContext) {
        let node = tile.node
        let dimmed = searchActive && node.searchMark == 0
        let size = Formatting.size(node.size)
        let textColor: Color =
            header || node.isDirectory
            ? (isDark ? .white : .black).opacity(dimmed ? 0.35 : 0.9)
            : palette.labelColor(for: node.kind).opacity(dimmed ? 0.35 : 1)

        context.drawLayer { layer in
            layer.clip(to: Path(rect.insetBy(dx: 3, dy: 1)))
            if header {
                // Header strip: "Name  1.2 GB" on one line, left aligned.
                let fontSize: CGFloat = 11
                let chars = max(Int((rect.width - 12) / (fontSize * 0.56)) - size.count - 2, 1)
                let text = Text(Formatting.truncateEnd(node.name, maxCharacters: chars) + "  " + size)
                    .font(.system(size: fontSize, weight: .semibold))
                    .foregroundStyle(textColor)
                layer.draw(text, at: CGPoint(x: rect.minX + 6, y: rect.minY + 8), anchor: .leading)
            } else {
                let fontSize = min(max(rect.width / 11, 10), 15)
                let chars = max(Int((rect.width - 8) / (fontSize * 0.56)), 1)
                let name = Text(Formatting.truncateEnd(node.name, maxCharacters: chars))
                    .font(.system(size: fontSize, weight: .medium))
                    .foregroundStyle(textColor)
                let center = CGPoint(x: rect.midX, y: rect.midY)
                if rect.height >= fontSize * 2.8 {
                    layer.draw(name, at: CGPoint(x: center.x, y: center.y - fontSize * 0.55), anchor: .center)
                    layer.draw(
                        Text(size).font(.system(size: fontSize - 2).monospacedDigit()).foregroundStyle(textColor.opacity(0.8)),
                        at: CGPoint(x: center.x, y: center.y + fontSize * 0.65), anchor: .center)
                } else {
                    layer.draw(name, at: center, anchor: .center)
                }
            }
        }
    }
}
