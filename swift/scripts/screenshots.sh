#!/bin/bash
# Captures each screenshot scene of the built app into a folder of PNGs.
# Usage: scripts/screenshots.sh path/to/Alocir.app output-folder
set -uo pipefail

app="${1:?usage: screenshots.sh Alocir.app output-folder}"
out="${2:?usage: screenshots.sh Alocir.app output-folder}"
binary="$app/Contents/MacOS/Alocir"
mkdir -p "$out"

scenes=$(grep -o '"[a-z-]*"' "$(dirname "$0")/../App/Support/ScreenshotMode.swift" \
    | sed -n '/"start"/,/"settings-dark"/p' | tr -d '"')

failed=0
for scene in $scenes; do
    log="$out/$scene.log"
    "$binary" -screenshot "$scene" -ApplePersistenceIgnoreState YES >"$log" 2>&1 &
    pid=$!
    line=""
    for _ in $(seq 1 300); do
        line=$(grep -m1 '^ALOCIR_' "$log" 2>/dev/null || true)
        [ -n "$line" ] && break
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.1
    done
    if [[ "$line" == ALOCIR_WINDOW=* ]]; then
        window=$(sed -E 's/ALOCIR_WINDOW=([0-9]+).*/\1/' <<<"$line")
        mode=$(sed -E 's/.*MODE=([a-z]+).*/\1/' <<<"$line")
        if [ "$mode" = screen ]; then
            sleep 1.5
            screencapture -x "$out/$scene.png"
        else
            sleep 0.5
            screencapture -x -o -l "$window" "$out/$scene.png"
        fi
        if [ -s "$out/$scene.png" ]; then
            echo "captured $scene"
            rm -f "$log"
        else
            echo "::warning::screencapture produced nothing for $scene"
            failed=1
        fi
    else
        echo "::warning::$scene did not report a window: ${line:-no output}"
        sed 's/^/    /' "$log" | tail -20
        failed=1
    fi
    kill "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
done
exit $failed
