import AlocirCore
import AppKit

/// Fits tile labels to the space they have, by measuring them in the same
/// system font the canvas draws with. Names are shortened in the middle
/// (keeping a file's extension) only when they really don't fit, and big
/// tiles get a second line first.
///
/// Measuring is the expensive part, so widths are cached; the cache is
/// dropped when it grows large. Main thread only, like the canvas.
@MainActor
final class LabelFitter {
    static let shared = LabelFitter()

    private struct WidthKey: Hashable {
        var text: String
        var size: CGFloat
        var weight: CGFloat
        var digits: Bool
    }

    private var widths: [WidthKey: CGFloat] = [:]
    private static let cacheLimit = 20_000

    /// Width of `text` on one line.
    func width(_ text: String, size: CGFloat, weight: NSFont.Weight, monospacedDigits: Bool = false) -> CGFloat {
        let key = WidthKey(text: text, size: size, weight: weight.rawValue, digits: monospacedDigits)
        if let width = widths[key] { return width }
        if widths.count >= Self.cacheLimit { widths.removeAll(keepingCapacity: true) }
        let font =
            monospacedDigits
            ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
            : NSFont.systemFont(ofSize: size, weight: weight)
        let width = ceil((text as NSString).size(withAttributes: [.font: font]).width)
        widths[key] = width
        return width
    }

    /// `name` as it fits in `maxWidth`: whole, or shortened in the middle.
    /// `nil` when not even a few characters fit.
    func fit(
        _ name: String, maxWidth: CGFloat, size: CGFloat, weight: NSFont.Weight, keepingExtension: Bool
    ) -> String? {
        guard maxWidth > 0 else { return nil }
        if width(name, size: size, weight: weight) <= maxWidth { return name }
        let count = name.count
        // Below three characters plus "…" a label says nothing.
        let shortest = 4
        guard count > shortest else { return nil }
        func candidate(_ n: Int) -> String {
            Formatting.truncateMiddle(name, maxCharacters: n, keepingExtension: keepingExtension)
        }
        func fits(_ n: Int) -> Bool { width(candidate(n), size: size, weight: weight) <= maxWidth }
        guard fits(shortest) else { return nil }
        // Binary search for the longest that fits, starting near an estimate
        // so most labels take two or three measurements.
        let estimate = min(max(Int(maxWidth / (size * 0.55)), shortest), count - 1)
        var low = shortest
        var high = count - 1
        if fits(estimate) {
            low = estimate
            if estimate + 3 < high, !fits(estimate + 3) { high = estimate + 2 }
        } else {
            high = estimate - 1
            if estimate - 3 > low, fits(estimate - 3) { low = estimate - 3 }
        }
        while low < high {
            let mid = (low + high + 1) / 2
            if fits(mid) { low = mid } else { high = mid - 1 }
        }
        return candidate(low)
    }

    /// `name` on two lines of `maxWidth`, for tiles tall enough: the first
    /// line is as much as fits, broken at a space, or else after a "-" or
    /// "_", and the second is the rest, shortened in the middle if it still
    /// doesn't fit. Never breaks inside a word or before a file's extension.
    /// `nil` when it fits on one line, has nowhere to break, or nothing fits.
    func fitTwoLines(
        _ name: String, maxWidth: CGFloat, size: CGFloat, weight: NSFont.Weight, keepingExtension: Bool
    ) -> (String, String)? {
        guard maxWidth > 0, width(name, size: size, weight: weight) > maxWidth else { return nil }
        let characters = Array(name)
        // Longest prefix that fits on the first line.
        var low = 0
        var high = characters.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if width(String(characters[..<mid]), size: size, weight: weight) <= maxWidth { low = mid } else { high = mid - 1 }
        }
        guard low >= 3 else { return nil }
        // Break in the last two thirds of what fits: at a space, or else
        // after a dash or underscore. A dot is left alone, so "Clip 12.mov"
        // never becomes "Clip 12." and "mov".
        let window = characters[(low / 3)..<low]
        let split: Int
        if let space = window.lastIndex(of: " ") {
            split = space + 1
        } else if let dash = window.lastIndex(where: { $0 == "-" || $0 == "_" }) {
            split = dash + 1
        } else {
            return nil
        }
        let first = String(characters[..<split]).trimmingCharacters(in: .whitespaces)
        let rest = String(characters[split...]).trimmingCharacters(in: .whitespaces)
        guard !first.isEmpty, !rest.isEmpty,
            let second = fit(rest, maxWidth: maxWidth, size: size, weight: weight, keepingExtension: keepingExtension)
        else { return nil }
        return (first, second)
    }
}
