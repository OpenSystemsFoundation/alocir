//! Searching the scanned tree. The query syntax matches the Mac edition's
//! `Search.swift`: tokens separated by spaces, all of which must match.
//!
//! | Token | Meaning |
//! |---|---|
//! | `report` | Name contains it, ignoring case |
//! | `.mp4` or `*.mp4` | Name ends with that extension |
//! | `>500mb`, `<1gb` | Size above or below (`b`, `kb`, `mb`, `gb`, `tb`) |
//!
//! Size tokens only match files: every folder above a big file is big too,
//! which would bury the files in folders.

use crate::scanner::FileNode;

/// `FileNode::mark` bit: the node matches the query.
pub const MATCH: u8 = 1;
/// `FileNode::mark` bit: something below the node matches.
pub const CONTAINS_MATCH: u8 = 2;

#[derive(Clone, Debug, PartialEq)]
pub enum Term {
    /// Lowercased.
    Name(String),
    /// Lowercased, without the dot.
    Extension(String),
    Larger(u64),
    Smaller(u64),
}

#[derive(Clone, Debug, PartialEq)]
pub struct SearchQuery {
    pub terms: Vec<Term>,
}

impl SearchQuery {
    /// `None` for an empty query.
    pub fn parse(text: &str) -> Option<SearchQuery> {
        let terms: Vec<Term> = text.split_whitespace().map(parse_term).collect();
        (!terms.is_empty()).then_some(SearchQuery { terms })
    }

    pub fn matches(&self, node: &FileNode) -> bool {
        self.terms.iter().all(|term| match term {
            Term::Name(text) => contains_ignoring_case(&node.name, text),
            Term::Extension(ext) => has_extension(&node.name, ext),
            Term::Larger(size) => !node.is_dir && node.size > *size,
            Term::Smaller(size) => !node.is_dir && node.size < *size,
        })
    }
}

fn parse_term(token: &str) -> Term {
    if let Some(rest) = token.strip_prefix('>') {
        if let Some(size) = parse_size(rest) {
            return Term::Larger(size);
        }
    }
    if let Some(rest) = token.strip_prefix('<') {
        if let Some(size) = parse_size(rest) {
            return Term::Smaller(size);
        }
    }
    let ext = token.strip_prefix('*').unwrap_or(token);
    if let Some(ext) = ext.strip_prefix('.') {
        if !ext.is_empty() {
            return Term::Extension(ext.to_lowercase());
        }
    }
    Term::Name(token.to_lowercase())
}

/// "500mb", "1.5GB", "200": bytes.
pub fn parse_size(text: &str) -> Option<u64> {
    let lower = text.to_ascii_lowercase();
    const UNITS: [(&str, f64); 9] = [
        ("tb", 1_099_511_627_776.0),
        ("gb", 1_073_741_824.0),
        ("mb", 1_048_576.0),
        ("kb", 1024.0),
        ("t", 1_099_511_627_776.0),
        ("g", 1_073_741_824.0),
        ("m", 1_048_576.0),
        ("k", 1024.0),
        ("b", 1.0),
    ];
    let (number, multiplier) = UNITS
        .iter()
        .find_map(|(suffix, value)| lower.strip_suffix(suffix).map(|n| (n, *value)))
        .unwrap_or((lower.as_str(), 1.0));
    let value: f64 = number.parse().ok()?;
    if !(value >= 0.0 && value.is_finite()) {
        return None;
    }
    Some((value * multiplier).min((u64::MAX / 2) as f64) as u64)
}

/// Whether `name` contains `needle` (already lowercased), ignoring case.
/// ASCII needles are compared byte by byte without allocating.
fn contains_ignoring_case(name: &str, needle: &str) -> bool {
    if needle.is_ascii() {
        let (hay, pat) = (name.as_bytes(), needle.as_bytes());
        if pat.is_empty() {
            return true;
        }
        if hay.len() < pat.len() {
            return false;
        }
        return hay
            .windows(pat.len())
            .any(|w| w.iter().zip(pat).all(|(a, b)| a.to_ascii_lowercase() == *b));
    }
    name.to_lowercase().contains(needle)
}

fn has_extension(name: &str, ext: &str) -> bool {
    let Some(dot) = name.rfind('.') else {
        return false;
    };
    let actual = &name[dot + 1..];
    if ext.is_ascii() {
        actual.eq_ignore_ascii_case(ext)
    } else {
        actual.to_lowercase() == ext
    }
}

/// What a search found.
#[derive(Clone, Debug, Default)]
pub struct SearchResult {
    /// Child indices from the root to each match, in tree order (parents
    /// before children). Valid until the tree changes.
    pub matches: Vec<Vec<u32>>,
    /// Total size of the matches, counting a match inside another once.
    pub total_size: u64,
}

/// Search the whole tree below `root`, marking every node (see [`MATCH`]
/// and [`CONTAINS_MATCH`]) and listing up to `limit` matches.
pub fn search(root: &mut FileNode, query: &SearchQuery, limit: usize) -> (SearchResult, usize) {
    let mut result = SearchResult::default();
    let mut count = 0;
    let mut path = Vec::new();
    root.mark = 0;
    let contains = visit(
        root,
        query,
        false,
        &mut path,
        &mut result,
        &mut count,
        limit,
    );
    if contains {
        root.mark |= CONTAINS_MATCH;
    }
    (result, count)
}

/// Marks `node`'s children and everything below them. Returns whether any
/// of them matches. `inside_match`: an ancestor already matched, so sizes
/// below it are already counted.
fn visit(
    node: &mut FileNode,
    query: &SearchQuery,
    inside_match: bool,
    path: &mut Vec<u32>,
    result: &mut SearchResult,
    count: &mut usize,
    limit: usize,
) -> bool {
    let mut any = false;
    for (i, child) in node.children.iter_mut().enumerate() {
        path.push(i as u32);
        let is_match = query.matches(child);
        child.mark = if is_match { MATCH } else { 0 };
        if is_match {
            any = true;
            *count += 1;
            if !inside_match {
                result.total_size += child.size;
            }
            if result.matches.len() < limit {
                result.matches.push(path.clone());
            }
        }
        if !child.children.is_empty()
            && visit(
                child,
                query,
                inside_match || is_match,
                path,
                result,
                count,
                limit,
            )
        {
            child.mark |= CONTAINS_MATCH;
            any = true;
        }
        path.pop();
    }
    any
}

/// Clear every mark below `root` (when the search is cleared).
pub fn clear_marks(root: &mut FileNode) {
    root.mark = 0;
    for child in &mut root.children {
        if child.mark != 0 || !child.children.is_empty() {
            clear_marks(child);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn file(name: &str, size: u64) -> FileNode {
        FileNode::new(name.into(), size, Vec::new(), false)
    }

    fn dir(name: &str, children: Vec<FileNode>) -> FileNode {
        let size = children.iter().map(|c| c.size).sum();
        FileNode::new(name.into(), size, children, true)
    }

    #[test]
    fn parses_every_token_kind() {
        let q = SearchQuery::parse("Report  .MP4 *.mov >1.5gb <10k").unwrap();
        assert_eq!(
            q.terms,
            vec![
                Term::Name("report".into()),
                Term::Extension("mp4".into()),
                Term::Extension("mov".into()),
                Term::Larger(1_610_612_736),
                Term::Smaller(10_240),
            ]
        );
        assert!(SearchQuery::parse("   ").is_none());
        // Not a size: treated as a name.
        assert_eq!(
            SearchQuery::parse(">big").unwrap().terms,
            vec![Term::Name(">big".into())]
        );
    }

    #[test]
    fn matching_ignores_case_and_checks_all_terms() {
        let q = SearchQuery::parse("clip .mp4").unwrap();
        assert!(q.matches(&file("Holiday CLIP 1.MP4", 1)));
        assert!(!q.matches(&file("Holiday clip.mov", 1)));
        let q = SearchQuery::parse("ünï").unwrap();
        assert!(q.matches(&file("ÜNÏCODE.txt", 1)));
        // Size terms skip folders.
        let q = SearchQuery::parse(">10").unwrap();
        assert!(q.matches(&file("a", 11)));
        assert!(!q.matches(&dir("d", vec![file("a", 11)])));
    }

    #[test]
    fn search_marks_and_counts_nested_matches_once() {
        let mut root = dir(
            "root",
            vec![
                dir("photos", vec![file("photo1.jpg", 50), file("notes.txt", 5)]),
                dir("photo-archive", vec![file("photo2.jpg", 30)]),
                file("other.bin", 7),
            ],
        );
        let q = SearchQuery::parse("photo").unwrap();
        let (result, count) = search(&mut root, &q, 100);
        // photos, photo1.jpg, photo-archive, photo2.jpg
        assert_eq!(count, 4);
        assert_eq!(
            result.matches,
            vec![vec![0], vec![0, 0], vec![1], vec![1, 0]]
        );
        // Matches inside a matching folder are counted once.
        assert_eq!(result.total_size, 55 + 30);
        assert_eq!(root.children[0].mark, MATCH | CONTAINS_MATCH);
        assert_eq!(root.children[0].children[1].mark, 0);
        assert_eq!(root.children[2].mark, 0);
        assert_eq!(root.mark, CONTAINS_MATCH);

        clear_marks(&mut root);
        assert_eq!(root.children[0].mark, 0);
        assert_eq!(root.children[0].children[0].mark, 0);
    }

    #[test]
    fn result_list_is_capped_but_count_is_not() {
        let mut root = dir(
            "root",
            (0..10).map(|i| file(&format!("f{i}.txt"), 1)).collect(),
        );
        let (result, count) = search(&mut root, &SearchQuery::parse(".txt").unwrap(), 3);
        assert_eq!(result.matches.len(), 3);
        assert_eq!(count, 10);
        assert_eq!(result.total_size, 10);
    }
}
