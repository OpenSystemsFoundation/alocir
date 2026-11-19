//! What a folder holds, for the inspector and for tinting folders on the
//! map. Matches the Mac edition's `FolderSummary.swift` and
//! `FolderKinds.swift`.

use crate::kind::FileKind;
use crate::scanner::FileNode;
use std::collections::HashMap;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct KindTotal {
    pub kind: FileKind,
    pub bytes: u64,
    pub files: u64,
}

/// Bytes and file counts by kind (the inspector's breakdown, which doubles
/// as the colour legend) and the largest files below a folder.
#[derive(Clone, Debug, Default)]
pub struct FolderSummary {
    /// Kinds with at least one file, largest first.
    pub kinds: Vec<KindTotal>,
    /// Child indices from the folder to each of its largest files, largest
    /// first. Valid until the tree changes.
    pub largest_files: Vec<Vec<u32>>,
    pub file_count: u64,
    pub folder_count: u64,
}

impl FolderSummary {
    /// One pass over the subtree.
    pub fn of(folder: &FileNode, limit: usize) -> FolderSummary {
        let mut bytes = [0u64; FileKind::COUNT];
        let mut counts = [0u64; FileKind::COUNT];
        // (size, path), kept sorted largest first; it stays short.
        let mut largest: Vec<(u64, Vec<u32>)> = Vec::with_capacity(limit + 1);
        let mut files = 0;
        let mut folders = 0;
        let mut path: Vec<u32> = Vec::new();
        walk(folder, &mut path, &mut |node, path| {
            if node.is_dir {
                folders += 1;
                return;
            }
            files += 1;
            bytes[node.kind as usize] += node.size;
            counts[node.kind as usize] += 1;
            if largest.len() < limit || largest.last().is_some_and(|l| node.size > l.0) {
                let at = largest.partition_point(|l| l.0 >= node.size);
                largest.insert(at, (node.size, path.to_vec()));
                largest.truncate(limit);
            }
        });
        let mut kinds: Vec<KindTotal> = FileKind::FILES
            .iter()
            .filter(|k| counts[**k as usize] > 0)
            .map(|&kind| KindTotal {
                kind,
                bytes: bytes[kind as usize],
                files: counts[kind as usize],
            })
            .collect();
        kinds.sort_by_key(|k| std::cmp::Reverse(k.bytes));
        FolderSummary {
            kinds,
            largest_files: largest.into_iter().map(|(_, p)| p).collect(),
            file_count: files,
            folder_count: folders,
        }
    }
}

/// Calls `visit` for every node below `node`, with its child-index path.
fn walk(node: &FileNode, path: &mut Vec<u32>, visit: &mut impl FnMut(&FileNode, &[u32])) {
    for (i, child) in node.children.iter().enumerate() {
        path.push(i as u32);
        visit(child, path);
        if !child.children.is_empty() {
            walk(child, path, visit);
        }
        path.pop();
    }
}

/// The kind of file taking the most space in `focus` and each folder below
/// it, down to `levels` levels (the map's nesting depth), keyed by the
/// folder's address. Addresses are only compared, never followed, and the
/// map is rebuilt whenever the tree changes. Folders without any files are
/// left out.
pub fn dominant_kinds(focus: &FileNode, levels: usize) -> HashMap<usize, FileKind> {
    let mut result = HashMap::new();
    totals(focus, 0, levels, &mut result);
    result
}

fn totals(
    folder: &FileNode,
    depth: usize,
    levels: usize,
    result: &mut HashMap<usize, FileKind>,
) -> [u64; FileKind::COUNT] {
    let mut bytes = [0u64; FileKind::COUNT];
    for child in &folder.children {
        if child.is_dir {
            if child.children.is_empty() {
                continue;
            }
            let sub = totals(child, depth + 1, levels, result);
            for (total, value) in bytes.iter_mut().zip(sub) {
                *total += value;
            }
        } else {
            bytes[child.kind as usize] += child.size;
        }
    }
    if depth <= levels {
        if let Some(kind) = dominant(&bytes) {
            result.insert(folder as *const FileNode as usize, kind);
        }
    }
    bytes
}

fn dominant(bytes: &[u64; FileKind::COUNT]) -> Option<FileKind> {
    let mut best = None;
    let mut best_bytes = 0;
    for kind in FileKind::FILES {
        let value = bytes[kind as usize];
        if value > best_bytes {
            best = Some(kind);
            best_bytes = value;
        }
    }
    best
}

/// The node at child-index `path` below `node`, if it is still there.
pub fn node_at<'a>(node: &'a FileNode, path: &[u32]) -> Option<&'a FileNode> {
    path.iter()
        .try_fold(node, |n, &i| n.children.get(i as usize))
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

    fn tree() -> FileNode {
        dir(
            "root",
            vec![
                dir("movies", vec![file("a.mp4", 900), file("b.mov", 600)]),
                dir(
                    "docs",
                    vec![file("c.pdf", 300), dir("deep", vec![file("d.zip", 500)])],
                ),
                file("e.txt", 10),
            ],
        )
    }

    #[test]
    fn summary_groups_by_kind_and_finds_largest_files() {
        let root = tree();
        let s = FolderSummary::of(&root, 3);
        assert_eq!(s.file_count, 5);
        assert_eq!(s.folder_count, 3);
        assert_eq!(
            s.kinds,
            vec![
                KindTotal {
                    kind: FileKind::Video,
                    bytes: 1500,
                    files: 2
                },
                KindTotal {
                    kind: FileKind::Archive,
                    bytes: 500,
                    files: 1
                },
                KindTotal {
                    kind: FileKind::Document,
                    bytes: 310,
                    files: 2
                },
            ]
        );
        let names: Vec<&str> = s
            .largest_files
            .iter()
            .map(|p| node_at(&root, p).unwrap().name.as_str())
            .collect();
        assert_eq!(names, ["a.mp4", "b.mov", "d.zip"]);
    }

    #[test]
    fn dominant_kind_per_folder() {
        let root = tree();
        let kinds = dominant_kinds(&root, 4);
        let key = |n: &FileNode| n as *const FileNode as usize;
        assert_eq!(kinds[&key(&root)], FileKind::Video);
        assert_eq!(kinds[&key(&root.children[0])], FileKind::Video);
        // docs: 300 of pdf, 500 of zip below it.
        assert_eq!(kinds[&key(&root.children[1])], FileKind::Archive);
        // Limited by depth.
        assert_eq!(dominant_kinds(&root, 0).len(), 1);
    }
}
