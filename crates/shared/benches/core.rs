//! Benchmarks for the hot paths: treemap layout and painting, the directory
//! scan, search, and the inspector's folder summary.
//!
//! Run with `cargo bench -p alocir-shared`. The scan benchmark uses a
//! generated tree in the system temp dir (created once, reused afterwards), so
//! it measures CPU and syscall overhead with a warm filesystem cache. Set
//! `ALOCIR_BENCH_DIR=/some/real/folder` to also benchmark a real folder.

use alocir_shared::scanner::{format_size, FileNode, ScanProgress};
use alocir_shared::search::{search, SearchQuery};
use alocir_shared::summary::{dominant_kinds, FolderSummary};
use alocir_shared::theme::{ColorScheme, ThemeColors};
use alocir_shared::treemap::{layout_nested, squarify, tile_nodes, NestedOptions};
use criterion::{black_box, criterion_group, criterion_main, BenchmarkId, Criterion};
use eframe::egui::{pos2, vec2, Context, Rect};
use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::sync::Arc;

/// Deterministic, heavy-tailed sizes (roughly Zipf), sorted descending, like
/// the children of a real directory.
fn sizes(n: usize) -> Vec<(usize, f64)> {
    let mut v: Vec<(usize, f64)> = (0..n)
        .map(|i| (i, 1.0e9 / ((i + 1) as f64).powf(1.1)))
        .collect();
    v.sort_by(|a, b| b.1.total_cmp(&a.1));
    v
}

fn bench_squarify(c: &mut Criterion) {
    let bounds = Rect::from_min_size(pos2(0.0, 0.0), vec2(1600.0, 1000.0));
    let mut group = c.benchmark_group("squarify");
    for n in [100usize, 1_000, 10_000, 50_000] {
        let items = sizes(n);
        group.bench_with_input(BenchmarkId::from_parameter(n), &items, |b, items| {
            b.iter(|| squarify(black_box(items), black_box(bounds)))
        });
    }
    group.finish();
}

/// Build (once) a tree of 200 dirs × 100 files plus some nesting: ~25k entries.
fn bench_tree() -> PathBuf {
    let root = std::env::temp_dir().join("alocir-bench-tree-v1");
    let marker = root.join(".complete");
    if marker.exists() {
        return root;
    }
    let _ = std::fs::remove_dir_all(&root);
    for d in 0..200 {
        let dir = root
            .join(format!("dir{d:03}"))
            .join(format!("sub{}", d % 5));
        std::fs::create_dir_all(&dir).unwrap();
        for f in 0..100 {
            let len = ((d * 100 + f) % 4096) as u64;
            let file = std::fs::File::create(dir.join(format!("file{f:03}.bin"))).unwrap();
            file.set_len(len).unwrap();
        }
    }
    std::fs::write(&marker, b"").unwrap();
    root
}

fn scan_once(path: &Path, ctx: &Context) -> FileNode {
    let progress = Arc::new(ScanProgress::new());
    let excluded = Arc::new(HashSet::new());
    FileNode::scan(path, &progress, &excluded, ctx)
}

fn bench_scan(c: &mut Criterion) {
    let ctx = Context::default();
    let tree = bench_tree();
    let mut group = c.benchmark_group("scan");
    group.sample_size(20);
    group.bench_function("generated_25k", |b| b.iter(|| scan_once(&tree, &ctx)));
    if let Ok(dir) = std::env::var("ALOCIR_BENCH_DIR") {
        group.sample_size(10);
        group.bench_function("real_dir", |b| b.iter(|| scan_once(Path::new(&dir), &ctx)));
    }
    group.finish();
}

/// What the treemap view did every frame for the current directory before
/// layouts were cached: lay out the children (now with the nested layout,
/// at depth 1 for a flat folder), then build a colour, name and size label
/// for each tile. Same inputs as before, so criterion's comparison holds.
fn bench_frame_prep(c: &mut Criterion) {
    let bounds = Rect::from_min_size(pos2(0.0, 0.0), vec2(1600.0, 1000.0));
    let theme: ThemeColors = ColorScheme::DarkMode.theme();
    let mut group = c.benchmark_group("frame_prep");
    for n in [1_000usize, 50_000] {
        let children: Vec<FileNode> = sizes(n)
            .into_iter()
            .map(|(i, s)| {
                FileNode::new(
                    format!("some_file_name_{i}.{}", ["rs", "png", "mp4", "txt"][i % 4]),
                    s as u64,
                    Vec::new(),
                    i % 10 == 0,
                )
            })
            .collect();
        let folder = FileNode::new("folder".into(), 0, children, true);
        let flat = NestedOptions {
            max_depth: 1,
            ..NestedOptions::default()
        };
        group.bench_with_input(BenchmarkId::from_parameter(n), &folder, |b, folder| {
            b.iter(|| {
                let tiles = layout_nested(folder, bounds, &flat);
                let nodes = tile_nodes(&tiles, folder);
                tiles
                    .iter()
                    .zip(nodes)
                    .map(|(tile, child)| {
                        (
                            tile.rect,
                            theme.tile_color(child, None),
                            child.name.clone(),
                            format_size(child.size),
                        )
                    })
                    .collect::<Vec<_>>()
            })
        });
    }
    group.finish();
}

/// A home-folder-like tree in memory: `dirs` folders of `files` files each,
/// one level of subfolders, heavy-tailed sizes, mixed kinds.
fn synthetic_tree(dirs: usize, files: usize) -> FileNode {
    const EXT: [&str; 8] = ["mp4", "jpg", "rs", "pdf", "zip", "plist", "txt", "bin"];
    let mut top: Vec<FileNode> = (0..dirs)
        .map(|d| {
            let mut subs: Vec<FileNode> = (0..4)
                .map(|s| {
                    let mut kids: Vec<FileNode> = (0..files / 4)
                        .map(|f| {
                            let i = d * files + s * 1000 + f;
                            let size = (1.0e9 / ((i % 9973 + 1) as f64).powf(1.1)) as u64 + 1;
                            FileNode::new(
                                format!("file_{d}_{s}_{f}.{}", EXT[i % EXT.len()]),
                                size,
                                Vec::new(),
                                false,
                            )
                        })
                        .collect();
                    kids.sort_unstable_by_key(|k| std::cmp::Reverse(k.size));
                    let size = kids.iter().map(|k| k.size).sum();
                    FileNode::new(format!("sub{s}"), size, kids, true)
                })
                .collect();
            subs.sort_unstable_by_key(|k| std::cmp::Reverse(k.size));
            let size = subs.iter().map(|k| k.size).sum();
            FileNode::new(format!("dir{d:04}"), size, subs, true)
        })
        .collect();
    top.sort_unstable_by_key(|k| std::cmp::Reverse(k.size));
    let size = top.iter().map(|k| k.size).sum();
    FileNode::new("home".into(), size, top, true)
}

/// The nested layout, computed when the folder, tree, size or depth
/// changes (not every frame): 200 folders × 1,000 files.
fn bench_nested_layout(c: &mut Criterion) {
    let bounds = Rect::from_min_size(pos2(0.0, 0.0), vec2(1600.0, 1000.0));
    let tree = synthetic_tree(200, 1_000);
    let mut group = c.benchmark_group("nested_layout");
    for depth in [1usize, 4, 8] {
        let options = NestedOptions {
            max_depth: depth,
            ..NestedOptions::default()
        };
        group.bench_with_input(
            BenchmarkId::from_parameter(depth),
            &options,
            |b, options| b.iter(|| layout_nested(black_box(&tree), bounds, options)),
        );
    }
    group.finish();
}

/// What the map does every frame with a cached nested layout: resolve each
/// tile's node and colour, as `paint_tiles` does, at the default depth.
fn bench_frame_paint(c: &mut Criterion) {
    let bounds = Rect::from_min_size(pos2(0.0, 0.0), vec2(1600.0, 1000.0));
    let theme: ThemeColors = ColorScheme::DarkMode.theme();
    let tree = synthetic_tree(200, 1_000);
    let tiles = layout_nested(&tree, bounds, &NestedOptions::default());
    let kinds = dominant_kinds(&tree, 4);
    c.bench_function("frame_paint/depth4", |b| {
        b.iter(|| {
            let nodes = tile_nodes(&tiles, &tree);
            let mut acc = 0u32;
            for (tile, node) in tiles.iter().zip(nodes) {
                let dominant = kinds.get(&(node as *const FileNode as usize)).copied();
                let color = theme.tile_color(node, dominant);
                acc = acc.wrapping_add(color.r() as u32 + tile.rect.width() as u32);
            }
            black_box(acc)
        })
    });
}

/// Searching a million files: a name, an extension and a size query. Each
/// runs once per pause in typing, or when the tree changes.
fn bench_search(c: &mut Criterion) {
    let mut tree = synthetic_tree(1_000, 1_000);
    let mut group = c.benchmark_group("search_1m");
    group.sample_size(20);
    for text in ["file_12", ".mp4", ">100mb"] {
        let query = SearchQuery::parse(text).unwrap();
        group.bench_function(text, |b| b.iter(|| search(&mut tree, &query, 200)));
    }
    group.finish();
}

/// The inspector's folder summary and the folder tints, each computed once
/// per folder or tree change, over a million files.
fn bench_summary(c: &mut Criterion) {
    let tree = synthetic_tree(1_000, 1_000);
    let mut group = c.benchmark_group("summary_1m");
    group.sample_size(20);
    group.bench_function("folder_summary", |b| {
        b.iter(|| FolderSummary::of(black_box(&tree), 20))
    });
    group.bench_function("dominant_kinds", |b| {
        b.iter(|| dominant_kinds(black_box(&tree), 4))
    });
    group.finish();
}

criterion_group!(
    benches,
    bench_squarify,
    bench_scan,
    bench_frame_prep,
    bench_nested_layout,
    bench_frame_paint,
    bench_search,
    bench_summary
);
criterion_main!(benches);
