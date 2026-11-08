#!/usr/bin/env bash
# Self-test: goal bodies are found by exact id, and validate rejects bodies an
# implementer would get wrong or not at all (F-16), for every oracle kind (F2-06).
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
GOALS_PY="$HERE/goals.py"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/cw-body-XXXXXX")"
export TMPDIR="$TMP" HOME="$TMP/home"; mkdir -p "$HOME"
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
# g1-store-extra (a file oracle) gets a body unless the markdown gives its own.
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
  [[ "$2" == *"## g1-store-extra"* ]] || printf '\n## g1-store-extra — Extra\nextra cases\n'
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
check "file-oracle goal without a body: invalid" "INVALID" "$(verdict "$TMP/file-oracle.md")"
check "error names the bodyless file-oracle goal" "1" "$(says "$TMP/file-oracle.md" 'g1-store: no ## g1-store section')"

goals tests/acceptance/test_store.py '
## g1-store — Store
**What it delivers:** stored mail' >"$TMP/file-oracle-body.md"
check "file-oracle goal with a body: valid" "OK" "$(verdict "$TMP/file-oracle-body.md")"

# required_sections: a target's duty, refused while a goal not yet done omits it.
sections() { # name, the key's line, goal status, extra body text
  printf '# Goals: sections\n\n```yaml\nplan: PLAN.md\njournal: j.md\n%s\ngoals:\n  - id: g1-store\n    title: Store\n    blocked_by: []\n    conflicts_with: []\n    area: mail\n    proof: "true"\n    oracle: tests/acceptance/g1-store.test.ts\n    status: %s\n```\n\n## g1-store — Store\n\n**What it delivers:** stored mail\n%b\n**Oracle:** x\n' "$2" "$3" "$4" >"$TMP/$1.md"
}
sections no-key "" ready ""
check "no required_sections: a body without it is valid" "OK" "$(verdict "$TMP/no-key.md")"
sections missing-section "required_sections: [Logging]" ready ""
check "a required section missing: invalid" "INVALID" "$(verdict "$TMP/missing-section.md")"
check "  ...the error names the goal and the section" "1" "$(says "$TMP/missing-section.md" 'g1-store: no \*\*Logging:\*\* section')"
sections blank-section "required_sections: [Logging]" ready "\n**Logging:**\n"
check "a required section with no text: invalid" "INVALID" "$(verdict "$TMP/blank-section.md")"
sections present-section "required_sections: [Logging]" ready "\n**Logging:** no new boundary: a test tool.\n"
check "a required section with text: valid" "OK" "$(verdict "$TMP/present-section.md")"
sections done-goal "required_sections: [Logging]" done ""
check "a done goal is not re-opened" "OK" "$(verdict "$TMP/done-goal.md")"
sections bad-key "required_sections: Logging" ready ""
check "required_sections not a list: invalid" "INVALID" "$(verdict "$TMP/bad-key.md")"
sections empty-key "required_sections: []" ready ""
check "required_sections empty: invalid" "INVALID" "$(verdict "$TMP/empty-key.md")"

goals tests/acceptance/test_store.py '
## g1-store — Store
first

## g1-store — Store again
second' >"$TMP/file-oracle-dup.md"
check "file-oracle goal, duplicate body: invalid" "1" "$(says "$TMP/file-oracle-dup.md" 'g1-store: 2 ## g1-store sections')"

goals inline '
## g1-store — Store
first

## g1-store — Store again
second' >"$TMP/dup.md"
check "duplicate section: invalid" "INVALID" "$(verdict "$TMP/dup.md")"
check "error names the duplicate" "1" "$(says "$TMP/dup.md" 'g1-store: 2 ## g1-store sections')"

# D-08: acceptance edits are the Architect's; "Edits owned" is implementer work.
goals inline '
## g1-store — Store
cases

**Acceptance edits (applied, read-only):** `tests/acceptance/test_g0.py` count 22 → 23

**Edits owned:** `pyproject.toml` packages += tools
- `tests/unit/test_store.py` row scope' >"$TMP/owned-ok.md"
check "owned files outside tests/acceptance: valid" "OK" "$(verdict "$TMP/owned-ok.md")"

goals inline '
## g1-store — Store
cases

**Edits owned:**
- `tests/unit/test_store.py` row scope
- `tests/acceptance/test_g0.py:187` count 22 → 23

**Out of scope:** retries' >"$TMP/owned-bad.md"
check "acceptance path under Edits owned: invalid" "INVALID" "$(verdict "$TMP/owned-bad.md")"
check "error names goal and path" "1" \
  "$(says "$TMP/owned-bad.md" 'g1-store: tests/acceptance/test_g0.py:187 is under \*\*Edits owned\*\*')"

goals inline '
## g1-store — Store
cases

**Edits owned:**
- `src/store.py`
- `tests/e2e/m1-pipeline.rs` corpus count

**Out of scope:** retries' >"$TMP/owned-e2e.md"
check "e2e path under Edits owned: invalid" "INVALID" "$(verdict "$TMP/owned-e2e.md")"
check "error names the e2e path" "1" \
  "$(says "$TMP/owned-e2e.md" 'g1-store: tests/e2e/m1-pipeline.rs is under \*\*Edits owned\*\*')"

goals inline '
## g1-store — Store
cases

**Edits owned:** `src/store.py`

**Out of scope:** changes to `tests/acceptance/test_g0.py`' >"$TMP/owned-later.md"
check "acceptance path in a later section: valid" "OK" "$(verdict "$TMP/owned-later.md")"

check "GOALS.example.md validates" "OK" "$(verdict "$HERE/../GOALS.example.md")"
check "mock fixture validates" "OK" "$(verdict "$HERE/fixtures/GOALS.mock.md")"

if [[ "$fails" -eq 0 ]]; then
  echo "goals-body: OK"
else
  echo "goals-body: $fails FAILURE(S)" >&2
  exit 1
fi
