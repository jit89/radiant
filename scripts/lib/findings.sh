# shellcheck shell=bash
# Parsing the goal reviewer's verdict into actionable findings.
# Sourced by run-goal.sh; self-tested by install.sh --check.
#
# findings_touch_oracle reads $ORACLE from the caller's environment.

# Findings are the reviewer's "FIX: <path>:<line> — ..." lines and nothing
# else. The reviewer also numbers its six analysis headings (1. SPEC,
# 2. ORACLE, ...); scraping "^N." swept those up as defects and — because the
# ORACLE heading names the oracle — bounced clean reviews as oracle tampering.
# Writes the renumbered findings to $2 and the target path of each to $3.
extract_findings() {
  local src="$1" dest="$2" targets="$3"
  python3 - "$src" "$dest" "$targets" <<'FPY'
import re, sys

FIX_RE = re.compile(r"(?mi)^\s*(?:[-*]\s*)?(?:\*\*)?FIX:\**\s*(.+?)\s*$")
# Leading "<path>:<line>" or "<path>" up to the first separator.
TARGET_RE = re.compile(r"^[`'\"*]*([^\s:`'\"*]+)")

text = open(sys.argv[1], encoding="utf-8").read()
out, targets = [], []
for m in FIX_RE.finditer(text):
    body = m.group(1).strip().rstrip("*").strip()
    if not body:
        continue
    out.append(f"{len(out) + 1}. {body}")
    t = TARGET_RE.match(body)
    targets.append(t.group(1) if t else "")

open(sys.argv[2], "w", encoding="utf-8").write("\n".join(out) + ("\n" if out else ""))
open(sys.argv[3], "w", encoding="utf-8").write("\n".join(targets) + ("\n" if targets else ""))
print(len(out))
FPY
}

# True only when a finding asks the implementer to CHANGE the oracle — that
# is, the oracle is the target path the FIX line opens with. A finding that
# merely cites the oracle as the reason for a change elsewhere is legitimate
# and must not bounce the goal.
findings_touch_oracle() {
  local targets="$1"
  python3 - "$targets" "$ORACLE" <<'OPY'
import sys

paths = [p.strip().lower().lstrip("./")
         for p in open(sys.argv[1], encoding="utf-8").read().splitlines()
         if p.strip()]
oracle = (sys.argv[2] or "").strip().lower().lstrip("./")

for p in paths:
    if p.startswith("tests/acceptance/") or p == "tests/acceptance":
        sys.exit(0)
    if oracle and oracle != "inline" and p == oracle:
        sys.exit(0)
sys.exit(1)
OPY
}
