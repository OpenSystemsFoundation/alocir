#!/bin/bash
# Benchmark the Swift scanner against the Rust one on a real Mac.
#
#   ./swift/scripts/bench.sh ~          # your home folder
#   ./swift/scripts/bench.sh /          # the whole disk (give Terminal Full Disk Access first)
#
# Builds both in release mode, runs each three times on PATH (the first run
# warms the file system cache and is not counted), and prints item count,
# total bytes, wall time and peak memory side by side, then the time of the
# nested treemap layout of the scanned tree at 1600x1000.
#
# Paste the whole output back. Hosted CI runners can run this but their
# timings say nothing about a real Mac.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
repo="$(cd "$here/.." && pwd)"
target="${1:?usage: bench.sh PATH}"
runs=3

echo "Building release binaries..."
(cd "$here" && swift build -c release --product alocir-scan >/dev/null)
(cd "$repo" && cargo build --release -q -p alocir-shared --example scan_total)
swift_bin="$here/.build/release/alocir-scan"
rust_bin="$repo/target/release/examples/scan_total"

log="$(mktemp -d)"
# run NAME BINARY [ARGS...]: one run under /usr/bin/time -l; prints
# "bytes items seconds peak_rss_bytes".
run() {
    local name="$1"; shift
    /usr/bin/time -l "$@" "$target" >"$log/$name.out" 2>"$log/$name.time"
    local totals real rss
    totals=$(sed -n '1s/.*(\([0-9]*\) bytes), \([0-9]*\) items.*/\1 \2/p' "$log/$name.out")
    real=$(awk '/ real /{print $1; exit}' "$log/$name.time")
    rss=$(awk '/maximum resident set size/{print $1; exit}' "$log/$name.time")
    echo "$totals $real $rss"
}

declare -a rust_results swift_results
for i in $(seq 1 $runs); do
    echo "Run $i of $runs$( [[ $i == 1 ]] && echo ' (warm-up, not counted)')..."
    rust_results[$i]=$(run "rust$i" "$rust_bin")
    swift_results[$i]=$(run "swift$i" "$swift_bin")
done

echo
echo "Path: $target"
echo "Mac: $(sysctl -n hw.model), $(sysctl -n machdep.cpu.brand_string), $(( $(sysctl -n hw.memsize) / 1073741824 )) GB RAM, macOS $(sw_vers -productVersion)"
echo
printf "%-7s %-4s %16s %12s %10s %12s %10s\n" "" "run" "bytes" "items" "seconds" "peak MB" "bytes/item"
for i in $(seq 2 $runs); do
    for impl in rust swift; do
        if [[ $impl == rust ]]; then r=${rust_results[$i]}; else r=${swift_results[$i]}; fi
        read -r bytes items secs rss <<<"$r"
        printf "%-7s %-4s %16s %12s %10s %12.1f %10.0f\n" "$impl" "$i" "$bytes" "$items" "$secs" \
            "$(echo "$rss / 1048576" | bc -l)" "$(echo "$rss / ($items + 1)" | bc -l)"
    done
done

read -r rb ri _ _ <<<"${rust_results[$runs]}"
read -r sb si _ _ <<<"${swift_results[$runs]}"
echo
if [[ "$rb $ri" == "$sb $si" ]]; then
    echo "Totals match: $sb bytes, $si items"
else
    echo "TOTALS DIFFER: Rust $rb bytes / $ri items, Swift $sb bytes / $si items"
fi
if [[ "$target" == "/" ]]; then
    echo "df for comparison:"
    df -k / /System/Volumes/Data 2>/dev/null || df -k /
fi

echo
echo "Nested treemap layout of the scanned tree:"
"$swift_bin" --layout "$target" | tail -1
