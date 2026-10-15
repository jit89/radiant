#!/usr/bin/env bash
# Self-test: claude-implement.sh runs Haiku sandboxed with no credential in its
# environment, falls back ONCE to DeepSeek through the same harness on a safety
# flag or a decline (never on a rate limit), keys each thread to its provider,
# and leaves no key file behind. `claude` is a stub; nothing calls a model.
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
# Normalised: $TMPDIR ends in "/", and the launcher resolves its own paths.
TMP="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/cw-implement-XXXXXX")" && pwd)"
export TMPDIR="$TMP"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
mkdir -p "$HOME"
unset ANTHROPIC_API_KEY ANTHROPIC_BASE_URL DEEPSEEK_API_KEY IMPLEMENTER_MODEL \
  IMPLEMENTER_EFFORT IMPLEMENTER_FALLBACK IMPLEMENTER_DRY_RUN IMPLEMENTER_ALLOWED_DOMAINS \
  IMPLEMENTER_MAX_BUDGET_USD DEEPSEEK_MODEL DEEPSEEK_ANTHROPIC_BASE_URL
export FAKE_SECRET_TOKEN=not-for-the-child
export GIT_AUTHOR_NAME=mock GIT_AUTHOR_EMAIL=mock@localhost
export GIT_COMMITTER_NAME=mock GIT_COMMITTER_EMAIL=mock@localhost
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

# A house of its own, so the real ~/claude-coding-workflow/.env never loads.
HOUSE="$TMP/house"
mkdir -p "$HOUSE/scripts"
cp -R "$HERE/." "$HOUSE/scripts/"
LAUNCHER="$HOUSE/scripts/claude-implement.sh"
KEYS_DIR="$HOME/.cache/claude-coding-workflow/keys"
ds_key_on() { printf 'DEEPSEEK_API_KEY=fake-ds-key\n' >"$HOUSE/.env"; }
ds_key_off() { rm -f "$HOUSE/.env"; }

# --- the stub: logs each call, then replays the Nth canned envelope -------------
FAKE_DIR="$TMP/fake"
FAKE="$TMP/claude"
cat >"$FAKE" <<'STUB'
#!/usr/bin/env bash
d="$FAKE_DIR"
n=$(( $(cat "$d/n" 2>/dev/null || echo 0) + 1 )); echo "$n" >"$d/n"
args=("$@"); model=""; sid=""; res=""; effort=""; settings=""; tools=""; allow=""; adddirs=""
safe=no; bare=no
for ((i = 0; i < ${#args[@]}; i++)); do
  case "${args[i]}" in
    --model) model="${args[i+1]}" ;;
    --session-id) sid="${args[i+1]}" ;;
    --resume) res="${args[i+1]}" ;;
    --effort) effort="${args[i+1]}" ;;
    --settings) settings="${args[i+1]}" ;;
    --tools) tools="${args[i+1]}" ;;
    --allowedTools) allow="${args[i+1]}" ;;
    --add-dir) adddirs="${adddirs}${args[i+1]};" ;;
    --safe-mode) safe=yes ;;
    --bare) bare=yes ;;
  esac
done
printf '%s' "$settings" >"$d/settings.$n"
printf '%s' "${args[1]:-}" >"$d/prompt.$n"
helper="$(printf '%s' "$settings" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("apiKeyHelper",""))')"
helper_out=""
[[ -z "$helper" ]] || helper_out="$(eval "$helper")"
echo "model=$model sid=$sid resume=$res effort=$effort safe=$safe bare=$bare tools=$tools allow=$allow base=${ANTHROPIC_BASE_URL:-} anthkey=${ANTHROPIC_API_KEY:+set} dskey=${DEEPSEEK_API_KEY:+set} secret=${FAKE_SECRET_TOKEN:+set} helper_out=$helper_out adddirs=$adddirs" >>"$d/calls"
[[ -f "$d/resp.$n" ]] || { echo "no canned response $n" >&2; exit 9; }
[[ -f "$d/err.$n" ]] && cat "$d/err.$n" >&2
sed "s/SID/${sid:-$res}/" "$d/resp.$n"
[[ -f "$d/rc.$n" ]] && exit "$(cat "$d/rc.$n")"
exit 0
STUB
chmod +x "$FAKE"

USAGE='"total_cost_usd":0.0125,"usage":{"input_tokens":100,"output_tokens":20,"cache_read_input_tokens":5,"cache_creation_input_tokens":7}'
DONE='{"type":"result","is_error":false,"stop_reason":"end_turn","result":"Implemented.\nIMPLEMENTER_STATUS: DONE","session_id":"SID",'"$USAGE"'}'
BLOCKED='{"type":"result","is_error":false,"stop_reason":"end_turn","result":"Stuck.\nIMPLEMENTER_STATUS: BLOCKED","session_id":"SID",'"$USAGE"'}'
DECLINED='{"type":"result","is_error":false,"stop_reason":"end_turn","result":"I will not do this.\nIMPLEMENTER_STATUS: DECLINED — not comfortable","session_id":"SID",'"$USAGE"'}'
REFUSAL='{"type":"result","stop_reason":"refusal","stop_details":{"type":"refusal","category":"cyber"},"result":"","session_id":"SID"}'
LIMITED='{"type":"result","is_error":true,"api_error_status":429,"result":"API Error: 429 rate limit","session_id":"SID"}'

REPO="$TMP/repo"
mkdir -p "$REPO" && (cd "$REPO" && git init -q && git commit -q --allow-empty -m base)
RUN_DIR="$TMP/run"
mkdir -p "$RUN_DIR"
printf '# Handoff: g1-store\n' >"$RUN_DIR/handoff-g1-store-r0.md"
EXTRA="$TMP/extra"
mkdir -p "$EXTRA"

# run <extra env assignments...> -- <script args...>; sets OUT (stdout) and RC.
run() {
  local envs=()
  while [[ "$1" != "--" ]]; do envs+=("$1"); shift; done
  shift
  set +e
  OUT="$(cd "$REPO" && env "${envs[@]+"${envs[@]}"}" FAKE_DIR="$FAKE_DIR" CLAUDE_REAL_BIN="$FAKE" \
    "$LAUNCHER" "$@" 2>"$TMP/stderr")"
  RC=$?
  set -e
}
reset() {
  rm -rf "$FAKE_DIR"; mkdir -p "$FAKE_DIR"
  local i=1
  for body in "$@"; do printf '%s\n' "$body" >"$FAKE_DIR/resp.$i"; i=$((i + 1)); done
}
calls() { [[ -f "$FAKE_DIR/calls" ]] && wc -l <"$FAKE_DIR/calls" | tr -d ' ' || echo 0; }
call_field() { sed -n "${1}p" "$FAKE_DIR/calls" | tr ' ' '\n' | grep "^$2=" | head -n1 | cut -d= -f2-; }
line() { grep "^$1: " <<<"$OUT" | head -n1 | sed "s/^$1: //"; }
setting() {
  python3 - "$FAKE_DIR/settings.$1" "$2" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
for k in sys.argv[2].split("."):
    d = d.get(k) if isinstance(d, dict) else None
print(json.dumps(d) if not isinstance(d, (str, bool)) else str(d).lower() if isinstance(d, bool) else d)
PY
}
keys_left() { find "$KEYS_DIR" -type f 2>/dev/null | wc -l | tr -d ' '; }
HANDOFF="$RUN_DIR/handoff-g1-store-r0.md"

echo "== 1. haiku ok: sandboxed, safe mode, nothing secret in its environment =="
ds_key_on; reset "$DONE"
run -- --add-dir "$EXTRA" "$HANDOFF"
check "exit 0" 0 "$RC"
check "result ok" ok "$(line IMPLEMENTER_RESULT)"
check "status DONE" DONE "$(line IMPLEMENTER_STATUS)"
check "one call" 1 "$(calls)"
check "model haiku" claude-haiku-5-5 "$(call_field 1 model)"
check "effort xhigh" xhigh "$(call_field 1 effort)"
check "--safe-mode" yes "$(call_field 1 safe)"
check "not --bare" no "$(call_field 1 bare)"
check "tools" Bash,Read,Edit,Write,Glob,Grep,TodoWrite "$(call_field 1 tools)"
check "Bash allowed" Bash "$(call_field 1 allow)"
check "handoff dir added" yes "$(has "$RUN_DIR;" "$(call_field 1 adddirs)")"
check "extra dir added" yes "$(has "$EXTRA;" "$(call_field 1 adddirs)")"
check "sandbox on" true "$(setting 1 sandbox.enabled)"
check "no unsandboxed retry" false "$(setting 1 sandbox.allowUnsandboxedCommands)"
check "fail if no sandbox" true "$(setting 1 sandbox.failIfUnavailable)"
check "house .env read-denied" yes "$(has "$HOUSE/.env" "$(setting 1 sandbox.filesystem.denyRead)")"
check "keys dir read-denied" yes "$(has "$KEYS_DIR" "$(setting 1 sandbox.filesystem.denyRead)")"
check "Read tool denied the house .env" yes "$(has "Read(/$HOUSE/.env)" "$(setting 1 permissions.deny)")"
check "network closed" "[]" "$(setting 1 sandbox.network.allowedDomains)"
check "no base url" "" "$(call_field 1 base)"
check "no DeepSeek key in env" "" "$(call_field 1 dskey)"
check "no Anthropic key in env" "" "$(call_field 1 anthkey)"
check "other secrets stripped" "" "$(call_field 1 secret)"
check "OAuth: no apiKeyHelper" "" "$(call_field 1 helper_out)"
check "thread keyed to haiku" "haiku:$(call_field 1 sid)" "$(line THREAD_ID)"
check "model line" claude-haiku-5-5 "$(line IMPLEMENTER_MODEL)"
check "no fallback line" "" "$(line IMPLEMENTER_FALLBACK)"
check "cost line" 0.0125 "$(line IMPLEMENTER_COST_USD)"
check "token line" "in=100 out=20 cache_read=5 cache_write=7" "$(line IMPLEMENTER_TOKENS)"
check "return handoff beside the handoff" "$RUN_DIR/return-handoff-g1-store-r0.md" "$(line RETURN_HANDOFF)"
check "prompt names the handoff" yes "$(has "$HANDOFF" "$(cat "$FAKE_DIR/prompt.1")")"
check "prompt asks for the status line" yes "$(has "IMPLEMENTER_STATUS: <WORD>" "$(cat "$FAKE_DIR/prompt.1")")"
check "no key file left" 0 "$(keys_left)"

echo "== 1b. an Anthropic API key reaches haiku through apiKeyHelper only =="
reset "$DONE"
run ANTHROPIC_API_KEY=fake-anth-key -- "$HANDOFF"
check "exit 0" 0 "$RC"
check "not in the environment" "" "$(call_field 1 anthkey)"
check "helper serves it" fake-anth-key "$(call_field 1 helper_out)"
check "no key file left" 0 "$(keys_left)"

echo "== 1c. BLOCKED and a missing status line are still ok (the host assesses) =="
reset "$BLOCKED"
run -- "$HANDOFF"
check "blocked: exit 0" 0 "$RC"
check "blocked: status" BLOCKED "$(line IMPLEMENTER_STATUS)"
reset '{"type":"result","is_error":false,"stop_reason":"end_turn","result":"no status","session_id":"SID"}'
run -- "$HANDOFF"
check "missing: exit 0" 0 "$RC"
check "missing: status" MISSING "$(line IMPLEMENTER_STATUS)"

echo "== 2. safety flag -> one fresh DeepSeek pass through the same harness =="
reset "$REFUSAL" "$DONE"
run -- "$HANDOFF"
check "exit 0" 0 "$RC"
check "two calls" 2 "$(calls)"
check "call 2 on DeepSeek" deepseek-v4-flash "$(call_field 2 model)"
check "call 2 bare" yes "$(call_field 2 bare)"
check "call 2 not safe-mode" no "$(call_field 2 safe)"
check "call 2 base url" https://api.deepseek.com/anthropic "$(call_field 2 base)"
check "call 2 key via helper" fake-ds-key "$(call_field 2 helper_out)"
check "call 2 no key in env" "" "$(call_field 2 dskey)"
check "call 2 no anthropic key in env" "" "$(call_field 2 anthkey)"
check "call 2 fresh session" "" "$(call_field 2 resume)"
check "call 2 new session id" yes "$([[ -n "$(call_field 2 sid)" && "$(call_field 2 sid)" != "$(call_field 1 sid)" ]] && echo yes || echo no)"
check "call 2 sandboxed too" true "$(setting 2 sandbox.enabled)"
check "call 2 told of the decline" yes "$(has "A previous implementer declined this goal" "$(cat "$FAKE_DIR/prompt.2")")"
check "fallback named" "haiku -> deepseek (refusal)" "$(line IMPLEMENTER_FALLBACK)"
check "judging model named" deepseek-v4-flash "$(line IMPLEMENTER_MODEL)"
check "thread keyed to deepseek" "deepseek:$(call_field 2 sid)" "$(line THREAD_ID)"
check "notice on stderr" yes "$(has "running it once on deepseek-v4-flash" "$(cat "$TMP/stderr")")"
check "no key file left" 0 "$(keys_left)"

echo "== 2b. --deny-write reaches every pass, the fallback included =="
reset "$REFUSAL" "$DONE"
run -- --deny-write /x/.git/refs/heads/walk --deny-write /x/.git/packed-refs "$HANDOFF"
check "deny-write: exit 0" 0 "$RC"
check "deny-write on the Haiku pass" '["/x/.git/refs/heads/walk", "/x/.git/packed-refs"]' \
  "$(setting 1 sandbox.filesystem.denyWrite)"
check "deny-write on the DeepSeek fallback" '["/x/.git/refs/heads/walk", "/x/.git/packed-refs"]' \
  "$(setting 2 sandbox.filesystem.denyWrite)"
check "deny-write keeps the read denials" yes "$(has "$HOUSE/.env" "$(setting 1 sandbox.filesystem.denyRead)")"
reset "$DONE"
run -- --deny-write relative/path "$HANDOFF"
check "deny-write: a relative path is refused" 2 "$RC"
check "deny-write: refused before any call" 0 "$(calls)"
reset "$DONE"
run -- "$HANDOFF"
check "no --deny-write: no denyWrite key" null "$(setting 1 sandbox.filesystem.denyWrite)"

echo "== 3. DECLINED -> fallback =="
reset "$DECLINED" "$DONE"
run -- "$HANDOFF"
check "exit 0" 0 "$RC"
check "two calls" 2 "$(calls)"
check "fallback named" "haiku -> deepseek (declined)" "$(line IMPLEMENTER_FALLBACK)"
check "status from DeepSeek" DONE "$(line IMPLEMENTER_STATUS)"

echo "== 4. both decline -> exit 76, no third call =="
reset "$DECLINED" "$DECLINED"
run -- "$HANDOFF"
check "exit 76" 76 "$RC"
check "two calls" 2 "$(calls)"
check "result" "declined (deepseek)" "$(line IMPLEMENTER_RESULT)"
check "no key file left" 0 "$(keys_left)"

echo "== 5. IMPLEMENTER_FALLBACK=none -> exit 76 on one call =="
reset "$REFUSAL" "$DONE"
run IMPLEMENTER_FALLBACK=none -- "$HANDOFF"
check "exit 76" 76 "$RC"
check "one call" 1 "$(calls)"
check "result" "flagged (haiku)" "$(line IMPLEMENTER_RESULT)"

echo "== 6. no DeepSeek key -> exit 76 on one call =="
ds_key_off; reset "$DECLINED" "$DONE"
run -- "$HANDOFF"
check "exit 76" 76 "$RC"
check "one call" 1 "$(calls)"
check "result" "declined (haiku)" "$(line IMPLEMENTER_RESULT)"
ds_key_on

echo "== 7. rate limit -> exit 75, no fallback =="
reset "$LIMITED" "$DONE"
printf '1\n' >"$FAKE_DIR/rc.1"
run -- "$HANDOFF"
check "exit 75" 75 "$RC"
check "one call" 1 "$(calls)"
check "result" "rate_limited (exit 1)" "$(line IMPLEMENTER_RESULT)"
check "no fallback line" "" "$(line IMPLEMENTER_FALLBACK)"

echo "== 8. --resume deepseek:<uuid> stays on DeepSeek; a refusal there gets no fallback =="
reset "$DONE"
run -- --resume deepseek:11111111-2222-3333-4444-555555555555 "$HANDOFF"
check "exit 0" 0 "$RC"
check "deepseek model" deepseek-v4-flash "$(call_field 1 model)"
check "resumed" 11111111-2222-3333-4444-555555555555 "$(call_field 1 resume)"
check "bare" yes "$(call_field 1 bare)"
check "thread kept" deepseek:11111111-2222-3333-4444-555555555555 "$(line THREAD_ID)"
reset "$REFUSAL" "$DONE"
run -- --resume deepseek:11111111-2222-3333-4444-555555555555 "$HANDOFF"
check "refused on resume: exit 76" 76 "$RC"
check "refused on resume: one call" 1 "$(calls)"

echo "== 8b. --resume haiku:<uuid> resumes Haiku =="
reset "$DONE"
run -- --resume haiku:aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee "$HANDOFF"
check "exit 0" 0 "$RC"
check "haiku model" claude-haiku-5-5 "$(call_field 1 model)"
check "resumed" aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee "$(call_field 1 resume)"

echo "== 8c. a thread that was never saved starts afresh on the same provider =="
reset "" "$DONE"
printf '%s\n' "No conversation found with session ID: aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee" >"$FAKE_DIR/err.1"
echo 1 >"$FAKE_DIR/rc.1"
run -- --resume haiku:aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee "$HANDOFF"
check "exit 0" 0 "$RC"
check "two calls" 2 "$(calls)"
check "call 1 resumed" aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee "$(call_field 1 resume)"
check "call 2 is a fresh session" "" "$(call_field 2 resume)"
check "call 2 stays on haiku" claude-haiku-5-5 "$(call_field 2 model)"
check "call 2 is told the session was lost" yes "$(has "previous session for this goal was lost" "$(cat "$FAKE_DIR/prompt.2")")"
check "new thread id" yes "$([[ "$OUT" == *"THREAD_ID: haiku:"* && "$OUT" != *"THREAD_ID: haiku:aaaaaaaa"* ]] && echo yes || echo "$OUT")"

echo "== 8d. the prompt asks for a status line the parser accepts =="
check "example line parses" DONE "$(printf 'IMPLEMENTER_STATUS: DONE\n' >"$TMP/st" && python3 "$HOUSE/scripts/lib/verdict.py" --key IMPLEMENTER_STATUS "$TMP/st" DONE BLOCKED DECLINED)"
check "prompt ends on that exact line" yes "$([[ "$(cat "$FAKE_DIR/prompt.2")" == *$'\nIMPLEMENTER_STATUS: DONE' ]] && echo yes || echo no)"

echo "== 8e. a resumed pass gets the new handoff, not the whole prompt again =="
check "resume names the handoff" yes "$(has "Read the handoff: $HANDOFF" "$(cat "$FAKE_DIR/prompt.1")")"
check "resume names the return handoff" yes "$(has "$RUN_DIR/return-handoff-g1-store-r0.md" "$(cat "$FAKE_DIR/prompt.1")")"
check "resume restates the status line" yes "$(has "End your reply with one line IMPLEMENTER_STATUS: DONE, BLOCKED or DECLINED" "$(cat "$FAKE_DIR/prompt.1")")"
check "resume restates the journal records" yes "$(has "Append a new START record for this pass" "$(cat "$FAKE_DIR/prompt.1")")"
check "resume keeps the rules by reference" yes "$(has "The rules from your first message still apply" "$(cat "$FAKE_DIR/prompt.1")")"
check "resume omits the numbered steps" yes "$(lacks "CHECKPOINT YOUR WORK" "$(cat "$FAKE_DIR/prompt.1")")"
check "fresh session keeps them" yes "$(has "CHECKPOINT YOUR WORK" "$(cat "$FAKE_DIR/prompt.2")")"
check "the sandbox line names \$TMPDIR, unexpanded" yes "$(has 'under $TMPDIR; put' "$(cat "$FAKE_DIR/prompt.2")")"

echo "== 8f. a resumed Haiku pass that declines falls back with the full prompt =="
reset "$DECLINED" "$DONE"
run -- --resume haiku:aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee "$HANDOFF"
check "two calls" 2 "$(calls)"
check "call 1 short" yes "$(lacks "CHECKPOINT YOUR WORK" "$(cat "$FAKE_DIR/prompt.1")")"
check "call 2 on DeepSeek" deepseek-v4-flash "$(call_field 2 model)"
check "call 2 told of the decline" yes "$(has "A previous implementer declined this goal" "$(cat "$FAKE_DIR/prompt.2")")"
check "call 2 has the full prompt" yes "$(has "CHECKPOINT YOUR WORK" "$(cat "$FAKE_DIR/prompt.2")")"

echo "== 9. a thread with no provider prefix is not ours =="
reset "$DONE"
run -- --resume 019a-codex-thread "$HANDOFF"
check "exit 2" 2 "$RC"
check "no call" 0 "$(calls)"
check "says whose" yes "$(has "set IMPLEMENTER=codex" "$OUT")"

echo "== 10. dry run calls nothing =="
reset "$DONE"
run IMPLEMENTER_DRY_RUN=1 -- "$HANDOFF"
check "exit 0" 0 "$RC"
check "dry_run" dry_run "$(line IMPLEMENTER_RESULT)"
check "no call" 0 "$(calls)"
check "command shown" yes "$(has "--safe-mode" "$OUT")"
check "no key file left" 0 "$(keys_left)"
run IMPLEMENTER_DRY_RUN=1 -- --smoke
check "smoke dry run exit 0" 0 "$RC"
check "smoke dry run: no call" 0 "$(calls)"

echo "== 11. the key never appears in what the launcher prints =="
reset "$REFUSAL" "$DONE"
run -- "$HANDOFF"
check "stdout clean" yes "$(lacks fake-ds-key "$OUT")"
check "stderr clean" yes "$(lacks fake-ds-key "$(cat "$TMP/stderr")")"
check "settings carry the path, not the key" yes "$(lacks fake-ds-key "$(cat "$FAKE_DIR/settings.2")")"

if [[ "$fails" -eq 0 ]]; then
  echo "implement-test: all passed"
else
  echo "implement-test: $fails failed"
  exit 1
fi
