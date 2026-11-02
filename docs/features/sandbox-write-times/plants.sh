#!/bin/bash
# Plants P0 (clean) to P6 for sandbox-write-times (EVIDENCE: proof-sandbox, the
# 2026-11-03 correction), each on its own copy of
# scripts/ with GOALS.example.md beside it; the live scripts/lib is never edited.
HOUSE="$(cd "$(dirname "$0")/../../.." && pwd)"
BASE="$HOME/dogfood/sbw-plants/run-$(date +%s)"
mkdir -p "$BASE"
mutate() { # dir plant
  /usr/bin/python3 - "$1/scripts/lib/proof-sandbox.py" "$2" <<'EOF'
import sys
p, plant = sys.argv[1], sys.argv[2]
s = open(p).read()
def rep(old, new, count=1):
    global s
    if s.count(old) != count:
        sys.exit(f"{plant}: expected {count} of {old!r}, found {s.count(old)}")
    s = s.replace(old, new)
W = 'WRITE = ("file-write* file-write-create'
if plant == "P1":
    rep(W, 'WRITE = ("file-write-create')
elif plant in ("P2", "P5"):
    d = '"file-write*"' if plant == "P5" else 'WRITE.replace("file-write* ", "")'
    rep('WRITE_EXTRA = ', f'WRITE_D = {d}\nWRITE_EXTRA = ')
    rep('(deny file-read* {WRITE} file-link', '(deny file-read* {WRITE_D} file-link', 3)
    rep('(deny {WRITE} file-link', '(deny {WRITE_D} file-link')
elif plant == "P3":
    rep('WRITE_EXTRA = ', 'WRITE_A = WRITE.replace("file-write* ", "")\nWRITE_EXTRA = ')
    s = s.replace('(allow {WRITE} ', '(allow {WRITE_A} ').replace('(allow file-read* {WRITE} ', '(allow file-read* {WRITE_A} ')
elif plant == "P4":
    rep('    L.append(f"(deny {WRITE_EXTRA}', '    L.append(f"(allow {WRITE} (subpath {lit(root)}))")\n    L.append(f"(deny {WRITE_EXTRA}')
elif plant == "P6":
    rep('    L.append(f"(deny {WRITE_EXTRA} {subpaths(extra)})")\n', '')
open(p, "w").write(s)
EOF
}
run() {
  local plant="$1" d="$BASE/$1"
  mkdir -p "$d" && cp -R "$HOUSE/scripts" "$d/scripts" && cp "$HOUSE/GOALS.example.md" "$d/"
  [[ "$plant" == P0 ]] || mutate "$d" "$plant" || { echo "$plant: mutation failed"; return; }
  bash "$d/scripts/tests/proof-sandbox-test.sh" >"$d/out.txt" 2>&1; local rc=$?
  { echo "=== $plant rc=$rc fails=$(grep -c '  FAIL' "$d/out.txt")"; grep '  FAIL' "$d/out.txt" | cut -c1-150; } >"$d/summary.txt"
}
for p in P0 P1 P2 P3 P4 P5 P6; do run "$p" & done
wait
cat "$BASE"/P*/summary.txt
