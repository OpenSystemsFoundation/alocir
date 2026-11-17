/// Sizes, counts, durations and `Character`-safe truncation for display.
///
/// File names can contain any Unicode, so strings are only ever shortened by
/// `Character` (grapheme cluster), never by byte or scalar index.
public enum Formatting {
    /// "512 B", "1.5 KB", "10.0 GB" (binary units, one decimal), as in the
    /// Rust app.
    public static func size(_ bytes: UInt64) -> String {
        let units: [(UInt64, String)] = [
            (1 << 40, "TB"), (1 << 30, "GB"), (1 << 20, "MB"), (1 << 10, "KB"),
        ]
        for (unit, name) in units where bytes >= unit {
            return oneDecimal(Double(bytes) / Double(unit)) + " " + name
        }
        return "\(bytes) B"
    }

    /// Thousands separators: 1234567 becomes "1,234,567".
    public static func count(_ n: UInt64) -> String {
        let digits = Array(String(n))
        var out = ""
        out.reserveCapacity(digits.count + digits.count / 3)
        for (i, digit) in digits.enumerated() {
            if i > 0 && (digits.count - i) % 3 == 0 { out.append(",") }
            out.append(digit)
        }
        return out
    }

    /// "0.4s", "12.3s", "2m 05s", "1h 02m".
    public static func duration(seconds: Double) -> String {
        let whole = UInt64(max(seconds, 0))
        if whole >= 3600 {
            return "\(whole / 3600)h \(twoDigits((whole % 3600) / 60))m"
        } else if whole >= 60 {
            return "\(whole / 60)m \(twoDigits(whole % 60))s"
        }
        return oneDecimal(max(seconds, 0)) + "s"
    }

    public static func duration(_ duration: Duration) -> String {
        let (secs, attos) = duration.components
        return self.duration(seconds: Double(secs) + Double(attos) / 1e18)
    }

    /// Share of a whole as "42%", or "<1%" for a small non-zero share.
    public static func percent(_ part: UInt64, of whole: UInt64) -> String {
        guard whole > 0 else { return "0%" }
        let value = Double(part) / Double(whole) * 100
        if part > 0 && value < 1 { return "<1%" }
        return "\(Int(value.rounded()))%"
    }

    /// At most `maxCharacters` characters, the end replaced by "…" when
    /// longer.
    public static func truncateEnd(_ s: String, maxCharacters: Int) -> String {
        guard s.count > maxCharacters else { return s }
        guard maxCharacters > 1 else { return "…" }
        return String(s.prefix(maxCharacters - 1)) + "…"
    }

    /// At most `maxCharacters` characters, the start replaced by "…" when
    /// longer (for paths, where the end matters most).
    public static func truncateStart(_ s: String, maxCharacters: Int) -> String {
        guard s.count > maxCharacters else { return s }
        guard maxCharacters > 1 else { return "…" }
        return "…" + String(s.suffix(maxCharacters - 1))
    }

    /// One decimal place, rounded half up, without Foundation.
    static func oneDecimal(_ value: Double) -> String {
        let tenths = UInt64((value * 10).rounded())
        return "\(tenths / 10).\(tenths % 10)"
    }

    private static func twoDigits(_ n: UInt64) -> String {
        n < 10 ? "0\(n)" : "\(n)"
    }
}
