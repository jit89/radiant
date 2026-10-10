#!/usr/bin/env bash
# Self-test: claude-goal-review.sh retries ONCE on a fallback model when the
# reviewer's safeguards flag the review, records which model judged, fails closed
# when it cannot, and does NOT fire on a review that merely quotes the flag wording
# or on a Usage Policy refusal. `claude` is a stub; nothing calls a model.
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/cw-fallback-XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
mkdir -p "$HOME"
unset ANTHROPIC_API_KEY ANTHROPIC_BASE_URL CLAUDE_REVIEW_MODEL CLAUDE_REVIEW_FALLBACK_MODEL
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
has() { [[ "$2" == *"$1"* ]] && echo yes || echo "no: $2"; }
lacks() { [[ "$2" != *"$1"* ]] && echo yes || echo "present: $1"; }

# --- the stub: logs each call, then replays the Nth canned envelope -------------
FAKE_DIR="$TMP/fake"
FAKE="$TMP/claude"
cat >"$FAKE" <<'STUB'
#!/usr/bin/env bash
d="$FAKE_DIR"
n=$(( $(cat "$d/n" 2>/dev/null || echo 0) + 1 )); echo "$n" >"$d/n"
args=("$@"); model=""; sid=""; res=""
for ((i = 0; i < ${#args[@]}; i++)); do
  case "${args[i]}" in
    --model) model="${args[i+1]}" ;;
    --session-id) sid="${args[i+1]}" ;;
    --resume) res="${args[i+1]}" ;;
  esac
done
pm="$(printf '%s' "${args[1]:-}" | grep -o '(model: [a-z0-9.-]*)' | head -n1 || true)"
echo "model=$model sid=$sid resume=$res prompt=$pm" >>"$d/calls"
[[ -f "$d/resp.$n" ]] || { echo "no canned response $n" >&2; exit 9; }
cat "$d/resp.$n"
[[ -f "$d/rc.$n" ]] && exit "$(cat "$d/rc.$n")"
exit 0
STUB
chmod +x "$FAKE"

FLAG_TEXT='{"type":"result","is_error":true,"result":"claude-opus-5-5'"'"'s safeguards flagged this message. This sometimes happens with safe, normal conversations.","session_id":"s-flag"}'
FLAG_CYBER='{"type":"result","is_error":true,"result":"claude-opus-5-5 has safety measures that flagged this message for a cybersecurity topic.","session_id":"s-flag"}'
FLAG_STOP='{"type":"result","stop_reason":"refusal","stop_details":{"type":"refusal","category":"cyber"},"result":"","session_id":"s-ref"}'
GOOD='{"type":"result","is_error":false,"result":"Reviewed the diff.\nVERDICT: DONE","session_id":"s-ok"}'
QUOTES='{"type":"result","is_error":false,"result":"The diff teaches the script to match the phrase safeguards flagged this message and retry.\nVERDICT: DONE","session_id":"s-ok"}'
POLICY='{"type":"result","is_error":true,"result":"Claude Code is unable to respond to this request, which appears to violate our Usage Policy.","session_id":"s-pol"}'

printf 'GOAL: g1\n' >"$TMP/brief.md"

# run <extra env assignments...> -- <script args...>; sets OUT (stdout) and RC.
run() {
  local envs=()
  while [[ "$1" != "--" ]]; do envs+=("$1"); shift; done
  shift
  set +e
  OUT="$(env "${envs[@]+"${envs[@]}"}" FAKE_DIR="$FAKE_DIR" CLAUDE_REAL_BIN="$FAKE" \
    CLAUDE_REVIEW_OUT="$TMP/verdict.md" "$HERE/claude-goal-review.sh" "$@" 2>"$TMP/stderr")"
  RC=$?
  set -e
}
reset() {
  rm -rf "$FAKE_DIR"; mkdir -p "$FAKE_DIR"
  local i=1
  for body in "$@"; do printf '%s\n' "$body" >"$FAKE_DIR/resp.$i"; i=$((i + 1)); done
}
calls() { wc -l <"$FAKE_DIR/calls" | tr -d ' '; }
call_field() { sed -n "${1}p" "$FAKE_DIR/calls" | tr ' ' '\n' | grep "^$2=" | head -n1 | cut -d= -f2-; }

echo "== 1. flagged -> retried once on the fallback, which judges =="
reset "$FLAG_TEXT" "$GOOD"
run -- "$TMP/brief.md"
check "exits 0" 0 "$RC"
check "result ok" yes "$(has 'CLAUDE_REVIEW_RESULT: ok' "$OUT")"
check "verdict comes from the fallback" yes "$(has 'VERDICT: DONE' "$OUT")"
check "the judging model is named" yes "$(has 'CLAUDE_REVIEW_MODEL: claude-opus-4-8' "$OUT")"
check "the switch is named" yes "$(has 'CLAUDE_REVIEW_FALLBACK: claude-opus-5-5 -> claude-opus-4-8 (safety flag)' "$OUT")"
check "two calls" 2 "$(calls)"
check "call 1 on the primary" claude-opus-5-5 "$(call_field 1 model)"
check "call 2 on the fallback" claude-opus-4-8 "$(call_field 2 model)"
check "a fresh review retries on a NEW session" yes \
  "$([[ -n "$(call_field 1 sid)" && "$(call_field 1 sid)" != "$(call_field 2 sid)" ]] && echo yes || echo no)"
check "the prompt names the model that is actually judging" '(model:' "$(call_field 2 prompt | cut -c1-8)"
check "  ...and it is the fallback" yes "$(has 'opus-4-8' "$(sed -n 2p "$FAKE_DIR/calls")")"
check "the notice reaches stderr" yes "$(has 'retrying once on claude-opus-4-8' "$(cat "$TMP/stderr")")"

echo "== 2. the cybersecurity wording and a bare stop_reason also count =="
reset "$FLAG_CYBER" "$GOOD"; run -- "$TMP/brief.md"
check "cyber wording -> two calls, ok" "2 ok" "$(calls) $(has 'CLAUDE_REVIEW_RESULT: ok' "$OUT" | sed 's/yes/ok/')"
reset "$FLAG_STOP" "$GOOD"; run -- "$TMP/brief.md"
check "stop_reason refusal -> two calls" 2 "$(calls)"

echo "== 3. a non-zero exit with a flag is still a flag, not a generic error =="
reset "$FLAG_TEXT" "$GOOD"; echo 1 >"$FAKE_DIR/rc.1"; run -- "$TMP/brief.md"
check "retried and ok" "2 0" "$(calls) $RC"

echo "== 4. no fallback -> fail closed (unset default is ON; 'none' and empty are OFF) =="
reset "$FLAG_TEXT" "$GOOD"; run CLAUDE_REVIEW_FALLBACK_MODEL=none -- "$TMP/brief.md"
check "none: exit 76" 76 "$RC"
check "none: result flagged" yes "$(has 'CLAUDE_REVIEW_RESULT: flagged' "$OUT")"
check "none: no verdict" yes "$(has 'VERDICT: MISSING' "$OUT")"
check "none: one call only" 1 "$(calls)"
reset "$FLAG_TEXT" "$GOOD"; run CLAUDE_REVIEW_FALLBACK_MODEL= -- "$TMP/brief.md"
check "empty (not unset) also disables it" "76 1" "$RC $(calls)"

echo "== 5. both flagged -> fail closed, and it says so =="
reset "$FLAG_TEXT" "$FLAG_TEXT"; run -- "$TMP/brief.md"
check "exit 76" 76 "$RC"
check "two calls, no third" 2 "$(calls)"
check "both-flagged is named" yes "$(has '(both flagged)' "$OUT")"
check "never a guessed DONE" yes "$(lacks 'VERDICT: DONE' "$OUT")"

echo "== 6. a --resume round keeps its session across the switch =="
reset "$FLAG_TEXT" "$GOOD"; run -- --resume sess-r1 "$TMP/brief.md"
check "call 1 resumes" sess-r1 "$(call_field 1 resume)"
check "call 2 resumes the same session" sess-r1 "$(call_field 2 resume)"
check "call 2 on the fallback" claude-opus-4-8 "$(call_field 2 model)"

echo "== 7. it must NOT fire when it should not =="
reset "$QUOTES"; run -- "$TMP/brief.md"
check "a review that quotes the flag wording: one call" 1 "$(calls)"
check "  ...judged by the primary" yes "$(has 'CLAUDE_REVIEW_MODEL: claude-opus-5-5' "$OUT")"
check "  ...no fallback line" yes "$(lacks 'CLAUDE_REVIEW_FALLBACK' "$OUT")"
reset "$POLICY"; run -- "$TMP/brief.md"
check "a Usage Policy refusal is NOT routed around: one call" 1 "$(calls)"
check "  ...no fallback line" yes "$(lacks 'CLAUDE_REVIEW_FALLBACK' "$OUT")"
reset "$GOOD"; run -- "$TMP/brief.md"
check "an ordinary review: one call, primary model" "1 claude-opus-5-5" "$(calls) $(call_field 1 model)"

echo "== 8. dry run and an explicit primary model =="
reset; run CLAUDE_REVIEW_DRY_RUN=1 -- "$TMP/brief.md"
check "dry run makes no call" yes "$(has 'CLAUDE_REVIEW_RESULT: dry_run' "$OUT")"
reset "$FLAG_TEXT" "$GOOD"; run CLAUDE_REVIEW_MODEL=claude-opus-4-8 -- "$TMP/brief.md"
check "fallback equal to the primary is not a retry" "76 1" "$RC $(calls)"

if [[ "$fails" -ne 0 ]]; then
  echo "review-fallback-test: $fails FAILED"
  exit 1
fi
echo "review-fallback-test: all passed"
