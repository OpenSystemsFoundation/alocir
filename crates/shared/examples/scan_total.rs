//! Scan a folder the way the app does and print the total, the largest
//! top-level entries and the time taken. Handy for checking totals against
//! `df` / `du`:
//!
//! ```text
//! cargo run --release -p alocir-shared --example scan_total -- /
//! ```

use alocir_shared::scanner::{format_size, FileNode, ScanProgress};
use std::collections::HashSet;
use std::path::PathBuf;
use std::sync::atomic::Ordering;
use std::sync::Arc;
use std::time::Instant;

fn main() {
    let path = PathBuf::from(std::env::args().nth(1).unwrap_or_else(|| ".".into()));
    let progress = Arc::new(ScanProgress::new());
    let excluded = Arc::new(HashSet::new());
    let ctx = eframe::egui::Context::default();

    let start = Instant::now();
    let node = FileNode::scan(&path, &progress, &excluded, &ctx);
    let elapsed = start.elapsed();

    println!(
        "{}: {} ({} bytes), {} items, {:.1}s",
        path.display(),
        format_size(node.size),
        node.size,
        progress.items_scanned.load(Ordering::Relaxed),
        elapsed.as_secs_f64()
    );
    for child in node.children.iter().take(12) {
        println!("  {:>10}  {}", format_size(child.size), child.name);
    }
}
