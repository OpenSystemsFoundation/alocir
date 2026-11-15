//! Character-safe string shortening for labels.
//!
//! Slicing a `str` by byte index panics when the index falls inside a
//! multi-byte character (accents, CJK, emoji), so file names must be shortened
//! by `char`s instead.

/// Keep at most `max_chars` characters, replacing the end with "..." when the
/// string is longer. Returns the string unchanged if it fits.
pub fn truncate_end(s: &str, max_chars: usize) -> String {
    if s.chars().count() <= max_chars {
        return s.to_string();
    }
    let keep = max_chars.saturating_sub(3);
    let cut = s.char_indices().nth(keep).map_or(s.len(), |(i, _)| i);
    format!("{}...", &s[..cut])
}

/// Keep at most `max_chars` characters, replacing the start with "..." when
/// the string is longer (for paths, where the end matters most).
pub fn truncate_start(s: &str, max_chars: usize) -> String {
    let count = s.chars().count();
    if count <= max_chars {
        return s.to_string();
    }
    let skip = count - max_chars.saturating_sub(3);
    let cut = s.char_indices().nth(skip).map_or(s.len(), |(i, _)| i);
    format!("...{}", &s[cut..])
}

/// Format a count with thousands separators: `1234567` becomes "1,234,567".
pub fn format_count(n: u64) -> String {
    let digits = n.to_string();
    let mut out = String::with_capacity(digits.len() + digits.len() / 3);
    for (i, c) in digits.chars().enumerate() {
        if i > 0 && (digits.len() - i).is_multiple_of(3) {
            out.push(',');
        }
        out.push(c);
    }
    out
}

/// Format a duration for display: "0.4s", "12.3s", "2m 05s", "1h 02m".
pub fn format_duration(d: std::time::Duration) -> String {
    let secs = d.as_secs();
    if secs >= 3600 {
        format!("{}h {:02}m", secs / 3600, (secs % 3600) / 60)
    } else if secs >= 60 {
        format!("{}m {:02}s", secs / 60, secs % 60)
    } else {
        format!("{:.1}s", d.as_secs_f64())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn counts_get_thousands_separators() {
        assert_eq!(format_count(0), "0");
        assert_eq!(format_count(999), "999");
        assert_eq!(format_count(1000), "1,000");
        assert_eq!(format_count(1234567), "1,234,567");
    }

    #[test]
    fn durations_are_compact() {
        use std::time::Duration;
        assert_eq!(format_duration(Duration::from_millis(450)), "0.5s");
        assert_eq!(format_duration(Duration::from_secs(125)), "2m 05s");
        assert_eq!(format_duration(Duration::from_secs(3725)), "1h 02m");
    }

    #[test]
    fn short_strings_unchanged() {
        assert_eq!(truncate_end("abc", 10), "abc");
        assert_eq!(truncate_start("abc", 10), "abc");
        assert_eq!(truncate_end("abcdefghij", 10), "abcdefghij");
    }

    #[test]
    fn ascii_truncation() {
        assert_eq!(truncate_end("abcdefghijkl", 10), "abcdefg...");
        assert_eq!(truncate_start("abcdefghijkl", 10), "...fghijkl");
    }

    #[test]
    fn multibyte_names_do_not_panic() {
        let name = "Ünïcödé 📁 föld€r — ünïcödé.txt";
        for max in 0..40 {
            let end = truncate_end(name, max);
            let start = truncate_start(name, max);
            assert!(end.chars().count() <= max.max(3));
            assert!(start.chars().count() <= max.max(3));
        }
        assert_eq!(truncate_end("😀😀😀😀😀😀", 5), "😀😀...");
        assert_eq!(truncate_start("😀😀😀😀😀😀", 5), "...😀😀");
    }
}
