//! Benchmarks for the hot paths: treemap layout (runs every frame) and the
//! directory scan.
//!
//! Run with `cargo bench -p alocir-shared`. The scan benchmark uses a
//! generated tree in the system temp dir (created once, reused afterwards), so
//! it measures CPU and syscall overhead with a warm filesystem cache. Set
//! `ALOCIR_BENCH_DIR=/some/real/folder` to also benchmark a real folder.

use alocir_shared::scanner::{format_size, FileNode, ScanProgress};
use alocir_shared::theme::{ColorScheme, ThemeColors};
use alocir_shared::treemap::{layout_visible, squarify};
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

/// What the treemap view does every frame for the current directory: lay out
/// the children, then build a colour, name and size label for each tile
/// (mirrors `show_treemap_ui` in crates/alocir/src/app.rs).
fn bench_frame_prep(c: &mut Criterion) {
    let bounds = Rect::from_min_size(pos2(0.0, 0.0), vec2(1600.0, 1000.0));
    let theme: ThemeColors = ColorScheme::DarkMode.theme();
    let mut group = c.benchmark_group("frame_prep");
    for n in [1_000usize, 50_000] {
        let children: Vec<FileNode> = sizes(n)
            .into_iter()
            .map(|(i, s)| FileNode {
                name: format!("some_file_name_{i}.{}", ["rs", "png", "mp4", "txt"][i % 4]),
                size: s as u64,
                children: Vec::new(),
                is_dir: i % 10 == 0,
            })
            .collect();
        group.bench_with_input(BenchmarkId::from_parameter(n), &children, |b, children| {
            b.iter(|| {
                layout_visible(children, bounds)
                    .iter()
                    .map(|item| {
                        let child = &children[item.index];
                        (
                            item.rect,
                            theme.color_for_node(&child.name, child.is_dir),
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

criterion_group!(benches, bench_squarify, bench_scan, bench_frame_prep);
criterion_main!(benches);
