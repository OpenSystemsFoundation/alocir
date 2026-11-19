#!/bin/bash
set -euo pipefail

# Check a macOS binary (or every executable in an .app bundle) for private
# Apple APIs, the way App Review's automated scan does: it reads the symbols
# the binary imports and the Objective-C selector names it contains.
#
# Usage: ./scripts/check-private-apis.sh <binary or .app> [...]
#
# Fails (exit 1) on:
#   - imported private C functions: CGS*/SLS*/CPS* (CoreGraphics Services,
#     SkyLight) and `_`-prefixed framework functions outside the standard
#     runtime allowlist below
#   - linked private frameworks (/System/Library/PrivateFrameworks)
#   - names of private functions in strings (dlsym lookups)
#   - undocumented Objective-C selectors: `_`-prefixed camelCase names
#     such as `_helpCursor` or `_wantsKeyDownForEvent:`, and known ones
#     without an underscore (DENY_SELECTORS)
#
# It can't prove a binary is clean (Apple's list is not public), but it
# catches what got Alocir 1.0.0 rejected. If it flags something that is
# public API, add it to the matching allowlist with a comment saying why.

# Imported `_`-prefixed symbols that are standard runtime/ABI, not private API.
# (nm prints C names with one extra leading underscore.)
# - swift*: the Swift runtime's ABI (libswiftCore and the overlays), which
#   every Swift binary imports, e.g. _swiftEmptyArrayStorage and the
#   _swift_FORCE_LOAD_$_swift<Module> autolink symbols.
# - objc_empty_cache: libobjc's ABI symbol that every compiled class's
#   method cache points at.
# - availability_version_check: what `if #available` compiles to.
# - os_log_*, os_signpost_*: what the public os_log/Logger and signpost
#   APIs compile to.
ALLOW_SYMBOLS='^__(Block_|NSConcrete|NSGet(Argc|Argv|Environ|ExecutablePath)$|Unwind_|dispatch_|dyld_|exit$|tlv_|_|swift|objc_empty_cache$|availability_version_check$|os_log_|os_signpost_)'

# Undocumented selectors and functions without a telltale underscore.
DENY_SELECTORS='^(busyButClickableCursor|CGSMainConnectionID|CGSSetWindowBackgroundBlurRadius)$'

if [[ $# -eq 0 ]]; then
    echo "Usage: $0 <binary or .app> [...]" >&2
    exit 2
fi

binaries=()
for target in "$@"; do
    if [[ -d "$target" ]]; then
        # An .app bundle: every Mach-O file inside it.
        while IFS= read -r -d '' file; do
            if file -b "$file" | grep -q "Mach-O"; then
                binaries+=("$file")
            fi
        done < <(find "$target" -type f -print0)
    else
        binaries+=("$target")
    fi
done

status=0
report() {
    echo "  $1"
    status=1
}

for binary in "${binaries[@]}"; do
    echo "==> Checking $binary for private APIs"
    found=0

    for arch in $(lipo -archs "$binary"); do
        while IFS= read -r symbol; do
            [[ -z "$symbol" ]] && continue
            report "[$arch] private function imported: ${symbol#_}"
            found=1
        done < <(nm -u -arch "$arch" "$binary" | sort -u | grep -E '^_(CGS|SLS|CPS|SLPS)[A-Z]|^__[A-Za-z]' | grep -vE "$ALLOW_SYMBOLS" || true)
    done

    while IFS= read -r framework; do
        [[ -z "$framework" ]] && continue
        report "private framework linked: $framework"
        found=1
    done < <(otool -L "$binary" | awk 'NR > 1 {print $1}' | grep '/PrivateFrameworks/' | sort -u || true)

    # Selector-shaped names (`_helpCursor`, `_wantsKeyDownForEvent:`) only
    # count in Objective-C selector names (__objc_methname); private
    # function names looked up with dlsym (CGS*, SLS*, CPS*, the deny list)
    # count in C strings (__cstring) too.
    section_strings() {
        for arch in $(lipo -archs "$binary"); do
            otool -arch "$arch" -X -v -s __TEXT "$1" "$binary" 2>/dev/null \
                | sed -E 's/^[0-9a-f]+[[:space:]]+//'
        done | sort -u
    }
    # Instance variable names share __objc_methname with selectors; a Swift
    # class's stored properties appear there (`_isSearching`), so leave out
    # every name `otool -ov` lists as an ivar (the `name` after `offset`).
    ivar_names() {
        for arch in $(lipo -archs "$binary"); do
            otool -arch "$arch" -ov "$binary" 2>/dev/null \
                | awk '$1 == "offset" { ivar = 1; next } ivar && $1 == "name" { print $NF } { ivar = 0 }'
        done | sort -u
    }
    while IFS= read -r name; do
        [[ -z "$name" ]] && continue
        report "private selector named in the binary: $name"
        found=1
    done < <(comm -23 <(section_strings __objc_methname) <(ivar_names) | grep -E \
        -e '^_[a-z][A-Za-z0-9]*[A-Z][A-Za-z0-9]*(:([A-Za-z0-9]+:)*)?$' \
        -e "$DENY_SELECTORS" | awk 'length >= 8' || true)
    while IFS= read -r name; do
        [[ -z "$name" ]] && continue
        report "private function named in the binary: $name"
        found=1
    done < <(section_strings __cstring | grep -E \
        -e '^(CGS|SLS|CPS)[A-Z][A-Za-z]+$' \
        -e "$DENY_SELECTORS" || true)

    if [[ $found -eq 0 ]]; then
        echo "    none found"
    fi
done

if [[ $status -ne 0 ]]; then
    echo ""
    echo "Private APIs found. App Review rejects these (guideline 2.5.1)."
    echo "Most come from dependencies, such as winit in the Rust app."
fi
exit $status
