#!/usr/bin/env bash
# Self-test for lib/findings.sh — the reviewer-verdict parser.
# Regression: the six numbered analysis headings the reviewer prompt asks for
# used to be scraped as defects, and the "2. ORACLE — tests/acceptance/... is
# untouched" heading bounced clean reviews as oracle tampering.
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "$HERE/lib/findings.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fails=0

check() {
  local name="$1" want="$2" got="$3"
  if [[ "$want" == "$got" ]]; then
    echo "  ok   $name"
  else
    echo "  FAIL $name: want [$want] got [$got]"
    fails=$((fails + 1))
  fi
}

cat >"$TMP/verdict-clean-fix.md" <<'MD'
# Goal review: g3-parser

1. SPEC — the diff implements g3-parser and only that goal.
2. ORACLE — tests/acceptance/test_parse.py is unmodified and green.
3. TESTS — assertions are exact; a missing-EOF case would slip through.
4. FAKE SUCCESS — none observed.
5. CEILINGS — no unmarked load-bearing simplification.
6. SMELLS — long method in parse(), judgement call only.

FIX: src/parse.py:42 — off-by-one on the final chunk — use `<=`
FIX: src/parse.py:88 — missing validation — reject empty input to satisfy tests/acceptance/test_parse.py

VERDICT: FIX
MD

ORACLE="tests/acceptance/test_parse.py"
n="$(extract_findings "$TMP/verdict-clean-fix.md" "$TMP/f.txt" "$TMP/t.txt")"
check "analysis headings are not findings" "2" "$n"
check "first finding kept verbatim" \
  "1. src/parse.py:42 — off-by-one on the final chunk — use \`<=\`" \
  "$(head -n1 "$TMP/f.txt")"
check "targets are the leading paths" "src/parse.py
src/parse.py" "$(cat "$TMP/t.txt")"
if findings_touch_oracle "$TMP/t.txt"; then
  check "citing the oracle does not bounce" "no-bounce" "BOUNCED"
else
  check "citing the oracle does not bounce" "no-bounce" "no-bounce"
fi

cat >"$TMP/verdict-tamper.md" <<'MD'
The oracle is wrong.

FIX: tests/acceptance/test_parse.py:10 — assertion is inverted — flip it
VERDICT: FIX
MD
n="$(extract_findings "$TMP/verdict-tamper.md" "$TMP/f2.txt" "$TMP/t2.txt")"
check "tamper finding parsed" "1" "$n"
if findings_touch_oracle "$TMP/t2.txt"; then
  check "editing the oracle bounces" "BOUNCED" "BOUNCED"
else
  check "editing the oracle bounces" "BOUNCED" "no-bounce"
fi

ORACLE="inline"
cat >"$TMP/verdict-inline.md" <<'MD'
- **FIX:** `src/a.py:3` — wrong default — use 0
VERDICT: FIX
MD
n="$(extract_findings "$TMP/verdict-inline.md" "$TMP/f3.txt" "$TMP/t3.txt")"
check "bulleted/bolded FIX line parsed" "1" "$n"
check "backticked path stripped" "src/a.py" "$(cat "$TMP/t3.txt")"
if findings_touch_oracle "$TMP/t3.txt"; then
  check "inline oracle never bounces on path" "no-bounce" "BOUNCED"
else
  check "inline oracle never bounces on path" "no-bounce" "no-bounce"
fi

cat >"$TMP/verdict-none.md" <<'MD'
Looks good. 1. SPEC fine. 2. ORACLE untouched.
VERDICT: DONE
MD
n="$(extract_findings "$TMP/verdict-none.md" "$TMP/f4.txt" "$TMP/t4.txt")"
check "no FIX lines yields zero findings" "0" "$n"

if [[ "$fails" -eq 0 ]]; then
  echo "findings: OK"
else
  echo "findings: $fails FAILURE(S)" >&2
  exit 1
fi
