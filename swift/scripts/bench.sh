#!/bin/bash
# Benchmark the Swift scanner against the Rust one.
#
#   ./swift/scripts/bench.sh [--runs N] [--markdown] PATH [PATH...]
#
#   ./swift/scripts/bench.sh ~          # your home folder
#   ./swift/scripts/bench.sh /          # the whole disk (give Terminal Full Disk Access first)
#
# Builds both in release mode. For each PATH: one warm-up run of each (not
# counted, it fills the file system cache), then N timed runs of each,
# alternating Rust and Swift. Prints the median wall time and peak memory
# and checks that totals match, then the nested treemap layout time of the
# scanned tree at 1600x1000 (median of five). --markdown prints a table for
# a PR comment or job summary.
#
# On shared CI runners the timings are noisy and say little about a real
# Mac; medians of several runs make them comparable between Rust and Swift
# on the same machine, nothing more.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
repo="$(cd "$here/.." && pwd)"
runs=3
markdown=false
paths=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --runs) runs="$2"; shift 2 ;;
        --markdown) markdown=true; shift ;;
        *) paths+=("$1"); shift ;;
    esac
done
[[ ${#paths[@]} -gt 0 ]] || { echo "usage: bench.sh [--runs N] [--markdown] PATH..." >&2; exit 2; }

echo "Building release binaries..." >&2
(cd "$here" && swift build -c release --product alocir-scan >/dev/null)
(cd "$repo" && cargo build --release -q -p alocir-shared --example scan_total)
swift_bin="$here/.build/release/alocir-scan"
rust_bin="$repo/target/release/examples/scan_total"
log="$(mktemp -d)"

# run BINARY [ARGS...] PATH: one run under /usr/bin/time -l; prints
# "bytes items seconds peak_rss_bytes".
run() {
    /usr/bin/time -l "$@" >"$log/out" 2>"$log/time"
    local totals real rss
    totals=$(sed -n '1s/.*(\([0-9]*\) bytes), \([0-9]*\) items.*/\1 \2/p' "$log/out")
    real=$(awk '/ real /{print $1; exit}' "$log/time")
    rss=$(awk '/maximum resident set size/{print $1; exit}' "$log/time")
    echo "$totals $real $rss"
}
median() { sort -g | awk '{a[NR]=$1} END {if (NR%2) print a[(NR+1)/2]; else printf "%.3f\n", (a[NR/2]+a[NR/2+1])/2}'; }

machine="$(sysctl -n hw.model), $(sysctl -n machdep.cpu.brand_string), $(sysctl -n hw.ncpu) cores, $(( $(sysctl -n hw.memsize) / 1073741824 )) GB RAM, macOS $(sw_vers -productVersion)"
rows=()
status=0
for target in "${paths[@]}"; do
    echo "== $target: warm-up" >&2
    run "$rust_bin" "$target" >/dev/null
    run "$swift_bin" "$target" >/dev/null
    : >"$log/rust.t"; : >"$log/swift.t"; : >"$log/rust.m"; : >"$log/swift.m"
    for i in $(seq 1 "$runs"); do
        echo "== $target: run $i of $runs" >&2
        read -r rb ri rt rm <<<"$(run "$rust_bin" "$target")"
        read -r sb si st sm <<<"$(run "$swift_bin" "$target")"
        echo "$rt" >>"$log/rust.t"; echo "$rm" >>"$log/rust.m"
        echo "$st" >>"$log/swift.t"; echo "$sm" >>"$log/swift.m"
    done
    rt=$(median <"$log/rust.t"); st=$(median <"$log/swift.t")
    rm=$(median <"$log/rust.m"); sm=$(median <"$log/swift.m")
    match="yes"
    if [[ "$rb $ri" != "$sb $si" ]]; then
        match="NO (Rust $rb B / $ri, Swift $sb B / $si)"
        status=1
    fi
    layout=$("$swift_bin" --layout "$target" | tail -1 | sed 's/^layout 1600x1000: //')
    speedup=$(echo "$rt / $st" | bc -l)
    rows+=("$target|$si|$sb|$rt|$st|$(printf '%.2f' "$speedup")×|$(echo "$rm/1048576" | bc)|$(echo "$sm/1048576" | bc)|$(echo "$rm/($ri+1)" | bc)|$(echo "$sm/($si+1)" | bc)|$layout|$match")
done

if $markdown; then
    echo "Median of $runs runs after a warm-up, Rust and Swift alternating on the same runner. $machine."
    echo
    echo "| Path | Items | Bytes | Rust s | Swift s | Speed-up | Rust peak MB | Swift peak MB | Rust B/item | Swift B/item | Layout 1600×1000 | Totals match |"
    echo "|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|---|"
    for row in "${rows[@]}"; do echo "| ${row//|/ | } |"; done
else
    echo "Median of $runs runs after a warm-up. $machine"
    printf "%-40s %10s %14s %8s %8s %8s %9s %9s %8s %8s  %s\n" path items bytes rust_s swift_s speedup rust_MB swift_MB rust_B/i swift_B/i layout
    for row in "${rows[@]}"; do
        IFS='|' read -r p i b r s x rm sm rbi sbi l m <<<"$row"
        printf "%-40s %10s %14s %8s %8s %8s %9s %9s %8s %8s  %s  totals match: %s\n" "$p" "$i" "$b" "$r" "$s" "$x" "$rm" "$sm" "$rbi" "$sbi" "$l" "$m"
    done
fi
exit $status
