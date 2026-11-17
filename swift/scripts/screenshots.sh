#!/bin/bash
# Captures each screenshot scene of the built app into a folder of PNGs.
# Usage: scripts/screenshots.sh path/to/Alocir.app output-folder
set -uo pipefail

app="${1:?usage: screenshots.sh Alocir.app output-folder}"
out="${2:?usage: screenshots.sh Alocir.app output-folder}"
binary="$app/Contents/MacOS/Alocir"
mkdir -p "$out"

# SCENES="start map" captures only those; by default every CI scene.
scenes="${SCENES:-$(grep -o '"[a-z-]*"' "$(dirname "$0")/../App/Support/ScreenshotMode.swift" \
    | sed -n '/"start"/,/"settings-dark"/p' | tr -d '"')}"

timeout="${SCREENSHOT_TIMEOUT:-120}"
failed=0
for scene in $scenes; do
    log="$out/$scene.log"
    : >"$log"
    # Through Launch Services, so the app comes to the front like a real
    # launch: an inactive window draws its controls dimmed.
    open -n -F --stdout "$log" --stderr "$log" "$app" \
        --args -screenshot "$scene" -ApplePersistenceIgnoreState YES
    line=""
    # Slow runners (Intel, no GPU) can take most of a minute to draw the
    # first window.
    for _ in $(seq 1 $((timeout * 10))); do
        line=$(grep -m1 -E '^ALOCIR_(WINDOW|ERROR)' "$log" 2>/dev/null || true)
        [ -n "$line" ] && break
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
        else
            echo "::warning::screencapture produced nothing for $scene"
            failed=1
        fi
    else
        echo "::warning::$scene did not report a window within ${timeout}s: ${line:-no output}"
        sed 's/^/    /' "$log" | tail -20
        # What was on screen, and where the app's main thread was.
        screencapture -x "$out/$scene-timeout.png" 2>/dev/null
        pid=$(pgrep -n -f "$binary")
        if [ -n "$pid" ]; then
            echo "    main thread of $pid:"
            sample "$pid" 2 -file "$out/$scene-sample.txt" >/dev/null 2>&1
            # Named frames of the main thread's call tree, then the hottest
            # leaf functions.
            sed -n '/DispatchQueue_1/,/^ *[0-9]* Thread_/p' "$out/$scene-sample.txt" \
                | grep -v '???' | sed -E 's/^[ +!:|]*//' | awk '!seen[$0]++' | head -120 | sed 's/^/    /' | cut -c1-180
            echo "    hottest frames:"
            sed -n '/Sort by top of stack/,/^$/p' "$out/$scene-sample.txt" | head -25 | sed 's/^/    /'
        else
            echo "    the app is no longer running"
        fi
        failed=1
    fi
    grep '^ALOCIR_NOTE' "$log" | sed "s/^/    $scene: /"
    pkill -f "$binary" 2>/dev/null
    for _ in $(seq 1 50); do pgrep -f "$binary" >/dev/null || break; sleep 0.1; done
done
exit $failed
