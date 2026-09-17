#!/usr/bin/env bash
# Self-test: goal bodies are found by exact id, and validate rejects bodies an
# implementer would get wrong or not at all (F-16).
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
GOALS_PY="$HERE/goals.py"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/cw-body-XXXXXX")"
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

# goals <oracle-for-g1-store> <markdown after the fence>
goals() {
  cat <<EOF
# Goals: body fixture

\`\`\`yaml
plan: PLAN.md
journal: docs/journal/x.md
goals:
  - id: g1-store
    title: Store
    blocked_by: []
    conflicts_with: []
    area: a
    proof: true
    oracle: $1
    status: ready
  - id: g1-store-extra
    title: Extra
    blocked_by: []
    conflicts_with: []
    area: b
    proof: pytest tests/acceptance/test_extra.py
    oracle: tests/acceptance/test_extra.py
    status: ready
\`\`\`
$2
EOF
}
first_line() { "$GOALS_PY" "$1" body "$2" 2>&1 | head -n1 || true; }
verdict() { "$GOALS_PY" "$1" validate 2>&1 | head -n1 | awk '{print $1}' || true; }
says() { "$GOALS_PY" "$1" validate 2>&1 | grep -c "$2" || true; }

goals inline '
## g1-store-extra — Extra
extra cases

## g1-store — Store
store cases' >"$TMP/prefix.md"
check "prefix id listed first: exact body" "## g1-store — Store" "$(first_line "$TMP/prefix.md" g1-store)"
check "longer id still finds its own" "## g1-store-extra — Extra" "$(first_line "$TMP/prefix.md" g1-store-extra)"
check "prefix fixture validates" "OK" "$(verdict "$TMP/prefix.md")"

goals inline '
## g1-store
bare heading cases' >"$TMP/bare.md"
check "heading with no title" "## g1-store" "$(first_line "$TMP/bare.md" g1-store)"

goals inline '
## g1-store-extra — Extra
only the longer one' >"$TMP/missing.md"
check "missing section is an error, not the prefix match" "no markdown section for g1-store" \
  "$(first_line "$TMP/missing.md" g1-store)"
check "inline goal without a body: invalid" "INVALID" "$(verdict "$TMP/missing.md")"
check "error names the goal" "1" "$(says "$TMP/missing.md" 'g1-store: oracle: inline but no ## g1-store section')"

goals tests/acceptance/test_store.py '' >"$TMP/file-oracle.md"
check "file-oracle goals may omit bodies" "OK" "$(verdict "$TMP/file-oracle.md")"

goals inline '
## g1-store — Store
first

## g1-store — Store again
second' >"$TMP/dup.md"
check "duplicate section: invalid" "INVALID" "$(verdict "$TMP/dup.md")"
check "error names the duplicate" "1" "$(says "$TMP/dup.md" 'g1-store: 2 ## g1-store sections')"

check "GOALS.example.md validates" "OK" "$(verdict "$HERE/../GOALS.example.md")"
check "mock fixture validates" "OK" "$(verdict "$HERE/fixtures/GOALS.mock.md")"

if [[ "$fails" -eq 0 ]]; then
  echo "goals-body: OK"
else
  echo "goals-body: $fails FAILURE(S)" >&2
  exit 1
fi
