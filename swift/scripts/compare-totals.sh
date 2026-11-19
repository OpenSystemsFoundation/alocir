#!/bin/bash
# Scans the same folder with the Swift `alocir-scan` and the Rust
# `scan_total` example and fails if their totals (bytes and items) differ.
# With no folder given, builds a test tree with nested folders, hard links,
# a sparse file, symlinks, a FIFO and Unicode names.
#
#   ./swift/scripts/compare-totals.sh [FOLDER]
#
# Correctness only: hosted CI runners say nothing about real-Mac speed.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
repo="$(cd "$here/.." && pwd)"

if [[ $# -ge 1 ]]; then
    tree="$1"
else
    tree="$(mktemp -d)/tree"
    mkdir -p "$tree"
    for i in $(seq 1 30); do
        mkdir -p "$tree/d$i/sub/deeper"
        for j in $(seq 1 20); do
            head -c $((i * j * 137)) /dev/urandom > "$tree/d$i/f$j.bin"
        done
        head -c $((i * 4099)) /dev/urandom > "$tree/d$i/sub/deeper/g.dat"
    done
    head -c 300000 /dev/urandom > "$tree/linked.bin"
    ln "$tree/linked.bin" "$tree/d1/hardlink.bin"
    ln "$tree/linked.bin" "$tree/d2/hardlink2.bin"
    mkfile -n 200m "$tree/sparse.img" 2>/dev/null || truncate -s 200M "$tree/sparse.img"
    ln -s "$tree/d3" "$tree/symlink-to-dir"
    ln -s "$tree/linked.bin" "$tree/symlink-to-file"
    mkfifo "$tree/fifo"
    mkdir -p "$tree/Ünïcödé 📁"
    echo "héllo" > "$tree/Ünïcödé 📁/naïve.txt"
    mkdir -p "$tree/empty"
fi

(cd "$here" && swift build -c release --product alocir-scan >/dev/null)
(cd "$repo" && cargo build --release -q -p alocir-shared --example scan_total)
swift_bin="$here/.build/release/alocir-scan"
rust_bin="$repo/target/release/examples/scan_total"

totals() { sed -n '1s/.*(\([0-9]*\) bytes), \([0-9]*\) items.*/\1 \2/p'; }

rust_out=$("$rust_bin" "$tree")
swift_out=$("$swift_bin" "$tree")
fallback_out=$("$swift_bin" --fallback "$tree")
echo "Rust:           $(head -1 <<<"$rust_out")"
echo "Swift:          $(head -1 <<<"$swift_out")"
echo "Swift fallback: $(head -1 <<<"$fallback_out")"

rust=$(totals <<<"$rust_out")
swift=$(totals <<<"$swift_out")
fallback=$(totals <<<"$fallback_out")
if [[ -z "$rust" || "$rust" != "$swift" || "$rust" != "$fallback" ]]; then
    echo "::error::Totals differ (bytes items): Rust '$rust', Swift '$swift', Swift fallback '$fallback'" >&2
    exit 1
fi
echo "Totals match: $rust (bytes items)"
