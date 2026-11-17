#!/bin/bash
# Builds a synthetic tree for benchmarks: 120,000 small files in 2,400
# folders up to five levels deep, plus a few big and hard-linked files.
#   ./swift/scripts/make-bench-tree.sh DIR
set -euo pipefail
root="${1:?usage: make-bench-tree.sh DIR}"
mkdir -p "$root"
python3 - "$root" <<'PY'
import os, sys
root = sys.argv[1]
n = 0
for a in range(12):
    for b in range(10):
        for c in range(20):
            d = os.path.join(root, f"a{a}", f"b{b}", f"c{c}")
            if c % 4 == 0:
                d = os.path.join(d, "deeper", "deepest")
            os.makedirs(d, exist_ok=True)
            for f in range(50):
                size = (n * 7919) % 20000
                with open(os.path.join(d, f"file-{f}.{('jpg','txt','mov','swift','zip')[f % 5]}"), "wb") as fh:
                    fh.write(b"x" * size)
                n += 1
big = os.path.join(root, "big.bin")
with open(big, "wb") as fh:
    fh.write(os.urandom(50 * 1024 * 1024))
os.link(big, os.path.join(root, "a0", "big-link.bin"))
print(f"{n} files", file=sys.stderr)
PY
