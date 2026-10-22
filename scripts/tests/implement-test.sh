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
  IMPLEMENTER_MAX_BUDGET_USD DEEPSEEK_MODEL DEEPSEEK_ANTHROPIC_BASE_URL IMPLEMENTER_PRIMARY \
  DEEPSEEK_EFFORT CLAUDE_CODE_EFFORT_LEVEL DEEPSEEK_PRICE_MISS DEEPSEEK_PRICE_HIT DEEPSEEK_PRICE_OUT \
  IMPLEMENTER_SMOKE_PROVIDER
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
args=("$@"); model=""; sid=""; res=""; effort=""; settings=""; tools=""; allow=""; adddirs=""; budget=""
safe=no; bare=no
for ((i = 0; i < ${#args[@]}; i++)); do
  case "${args[i]}" in
    --model) model="${args[i+1]}" ;;
    --session-id) sid="${args[i+1]}" ;;
    --resume) res="${args[i+1]}" ;;
    --effort) effort="${args[i+1]}" ;;
    --max-budget-usd) budget="${args[i+1]}" ;;
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
echo "model=$model sid=$sid resume=$res effort=$effort safe=$safe bare=$bare tools=$tools allow=$allow base=${ANTHROPIC_BASE_URL:-} anthkey=${ANTHROPIC_API_KEY:+set} dskey=${DEEPSEEK_API_KEY:+set} secret=${FAKE_SECRET_TOKEN:+set} helper_out=$helper_out adddirs=$adddirs budget=$budget cel=${CLAUDE_CODE_EFFORT_LEVEL:-}" >>"$d/calls"
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
check "cost basis thread on a Haiku pass" thread "$(line IMPLEMENTER_COST_BASIS)"
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
check "call 2 on DeepSeek" deepseek-flash "$(call_field 2 model)"
check "call 2 bare" yes "$(call_field 2 bare)"
check "call 2 not safe-mode" no "$(call_field 2 safe)"
check "call 2 base url" https://api.deepseek.com/anthropic "$(call_field 2 base)"
check "call 2 key via helper" fake-ds-key "$(call_field 2 helper_out)"
check "call 2 no key in env" "" "$(call_field 2 dskey)"
check "call 2 no anthropic key in env" "" "$(call_field 2 anthkey)"
check "call 2 fresh session" "" "$(call_field 2 resume)"
check "call 2 new session id" yes "$([[ -n "$(call_field 2 sid)" && "$(call_field 2 sid)" != "$(call_field 1 sid)" ]] && echo yes || echo no)"
check "call 2 sandboxed too" true "$(setting 2 sandbox.enabled)"
check "call 2 told of the decline" yes "$(has "A previous implementer on this goal" "$(cat "$FAKE_DIR/prompt.2")")"
check "fallback named" "haiku -> deepseek (refusal)" "$(line IMPLEMENTER_FALLBACK)"
check "judging model named" deepseek-flash "$(line IMPLEMENTER_MODEL)"
check "thread keyed to deepseek" "deepseek:$(call_field 2 sid)" "$(line THREAD_ID)"
check "notice on stderr" yes "$(has "running it once on deepseek-flash" "$(cat "$TMP/stderr")")"
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

echo "== 2c. read denials (docs/features/proof-sandbox step 6) =="
reset "$REFUSAL" "$DONE"
run -- --deny-read /x/runs --deny-read /x/handoffs/other "$HANDOFF"
check "deny-read: exit 0" 0 "$RC"
for n in 1 2; do
  check "deny-read: pass $n denies /x/runs" yes "$(has '/x/runs' "$(setting $n sandbox.filesystem.denyRead)")"
  check "deny-read: pass $n denies another handoff folder" yes "$(has '/x/handoffs/other' "$(setting $n sandbox.filesystem.denyRead)")"
done
check "deny-read: the shared secret list (~/.ssh)" yes "$(has "$HOME/.ssh" "$(setting 1 sandbox.filesystem.denyRead)")"
check "deny-read: the shared secret list (~/.config/cw-secrets)" yes "$(has "$HOME/.config/cw-secrets" "$(setting 1 sandbox.filesystem.denyRead)")"
check "deny-read: the Read tool is denied too" yes "$(has 'Read(//x/runs)' "$(setting 1 permissions.deny)")"
reset "$DONE"
run -- --deny-read relative/path "$HANDOFF"
check "deny-read: a relative path is refused" 2 "$RC"

echo "== 3. DECLINED -> fallback =="
reset "$DECLINED" "$DONE"
run -- "$HANDOFF"
check "exit 0" 0 "$RC"
check "two calls" 2 "$(calls)"
check "fallback named" "haiku -> deepseek (declined)" "$(line IMPLEMENTER_FALLBACK)"
check "the primary Haiku pass priced from its envelope" "haiku:$(call_field 1 sid) COST_USD=0.0125 COST_BASIS=thread" "$(line IMPLEMENTER_FALLBACK_FROM)"
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
check "deepseek model" deepseek-flash "$(call_field 1 model)"
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
check "call 2 on DeepSeek" deepseek-flash "$(call_field 2 model)"
check "call 2 told of the decline" yes "$(has "A previous implementer on this goal" "$(cat "$FAKE_DIR/prompt.2")")"
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

# --- DeepSeek as the primary (docs/features/deepseek-primary) -----------------
DS_DONE='{"type":"result","is_error":false,"stop_reason":"end_turn","result":"Implemented.\nIMPLEMENTER_STATUS: DONE","session_id":"SID","total_cost_usd":9.99,"usage":{"input_tokens":134,"output_tokens":93,"cache_read_input_tokens":25472,"cache_creation_input_tokens":0},"modelUsage":{"deepseek-flash":{"inputTokens":1000000,"cacheReadInputTokens":1000000,"cacheCreationInputTokens":0,"outputTokens":1000000}}}'
DS_REFUSAL='{"type":"result","stop_reason":"refusal","stop_details":{"type":"refusal"},"result":"","session_id":"SID","modelUsage":{"deepseek-flash":{"inputTokens":2000,"cacheReadInputTokens":0,"cacheCreationInputTokens":0,"outputTokens":1000}}}'
BAL_NUM='{"type":"result","is_error":true,"api_error_status":402,"terminal_reason":"api_error","result":"API Error: 402 {\"error\":{\"message\":\"Insufficient Balance\",\"type\":\"insufficient_quota\"}}","session_id":"SID"}'
BAL_STR='{"type":"result","is_error":true,"api_error_status":"402","terminal_reason":"api_error","result":"API Error: 402 Insufficient Balance","session_id":"SID"}'
OVER_STR='{"type":"result","is_error":true,"api_error_status":"503","terminal_reason":"api_error","result":"API Error: 503 Service Unavailable","session_id":"SID"}'
OVER_NUM='{"type":"result","is_error":true,"api_error_status":503,"terminal_reason":"api_error","result":"API Error: 503 Server Overloaded","session_id":"SID"}'
BAD_REQ='{"type":"result","is_error":true,"api_error_status":400,"terminal_reason":"api_error","result":"API Error: 400 Invalid Format","session_id":"SID"}'

echo "== 12. IMPLEMENTER_PRIMARY=deepseek: a new goal starts on DeepSeek =="
ds_key_on; reset "$DS_DONE"
run IMPLEMENTER_PRIMARY=deepseek -- "$HANDOFF"
check "exit 0" 0 "$RC"
check "one call" 1 "$(calls)"
check "model deepseek-flash" deepseek-flash "$(call_field 1 model)"
check "bare" yes "$(call_field 1 bare)"
check "base url" https://api.deepseek.com/anthropic "$(call_field 1 base)"
check "key via helper" fake-ds-key "$(call_field 1 helper_out)"
check "no effort flag by default (Claude Code sends high)" "" "$(call_field 1 effort)"
check "sandbox on" true "$(setting 1 sandbox.enabled)"
check "thread keyed to deepseek" "deepseek:$(call_field 1 sid)" "$(line THREAD_ID)"
check "no fallback line" "" "$(line IMPLEMENTER_FALLBACK)"
check "cost from modelUsage at the peak price, not the envelope's" 1.506 "$(line IMPLEMENTER_COST_USD)"
check "cost basis thread" thread "$(line IMPLEMENTER_COST_BASIS)"
check "tokens are this invocation's" "in=134 out=93 cache_read=25472 cache_write=0" "$(line IMPLEMENTER_TOKENS)"
reset "$DS_DONE"
run IMPLEMENTER_PRIMARY=deepseek DEEPSEEK_EFFORT=high -- "$HANDOFF"
check "DEEPSEEK_EFFORT reaches DeepSeek as --effort" high "$(call_field 1 effort)"
reset "$DS_DONE"
run IMPLEMENTER_PRIMARY=deepseek DEEPSEEK_PRICE_MISS=1 DEEPSEEK_PRICE_HIT=0 DEEPSEEK_PRICE_OUT=0 -- "$HANDOFF"
check "price overrides" 1 "$(line IMPLEMENTER_COST_USD)"

echo "== 13. no DeepSeek key: a DeepSeek pass fails closed, no Haiku =="
ds_key_off; reset "$DONE"
run IMPLEMENTER_PRIMARY=deepseek -- "$HANDOFF"
check "exit 1" 1 "$RC"
check "no call" 0 "$(calls)"
check "says why" yes "$(has "error (no DeepSeek key" "$OUT")"
reset "$DONE"
run IMPLEMENTER_PRIMARY=deepseek -- --resume deepseek:11111111-2222-3333-4444-555555555555 "$HANDOFF"
check "resumed deepseek thread: exit 1, no call" "1 0" "$RC $(calls)"
reset "$DONE"
run IMPLEMENTER_PRIMARY=deepseek -- --resume haiku:aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee "$HANDOFF"
check "resumed haiku thread needs no DeepSeek key" "0 1 claude-haiku-5-5" "$RC $(calls) $(call_field 1 model)"
reset "$REFUSAL" "$DONE"
run -- "$HANDOFF"
check "haiku primary, no DeepSeek key: no fallback to DeepSeek" "76 1" "$RC $(calls)"
ds_key_on

echo "== 14. DeepSeek refuses (stop_reason refusal) -> one fresh Haiku pass =="
reset "$DS_REFUSAL" "$DONE"
run IMPLEMENTER_PRIMARY=deepseek -- "$HANDOFF"
check "exit 0" 0 "$RC"
check "two calls" 2 "$(calls)"
check "call 2 on haiku" claude-haiku-5-5 "$(call_field 2 model)"
check "call 2 safe-mode, not bare" "yes no" "$(call_field 2 safe) $(call_field 2 bare)"
check "call 2 no base url" "" "$(call_field 2 base)"
check "call 2 effort xhigh" xhigh "$(call_field 2 effort)"
check "call 2 fresh session" "" "$(call_field 2 resume)"
check "call 2 told why" yes "$(has "A previous implementer on this goal refused it" "$(cat "$FAKE_DIR/prompt.2")")"
check "fallback named" "deepseek -> haiku (refusal)" "$(line IMPLEMENTER_FALLBACK)"
check "the primary's thread and cost" "deepseek:$(call_field 1 sid) COST_USD=0.0018 COST_BASIS=thread" "$(line IMPLEMENTER_FALLBACK_FROM)"
check "thread keyed to haiku" "haiku:$(call_field 2 sid)" "$(line THREAD_ID)"
check "Haiku's cost from its envelope" 0.0125 "$(line IMPLEMENTER_COST_USD)"
reset "$DS_DONE" "$DONE"
check "a declined DeepSeek pass falls back too" "0 2 deepseek -> haiku (declined)" \
  "$(printf '%s\n' "$DECLINED" >"$FAKE_DIR/resp.1"; run IMPLEMENTER_PRIMARY=deepseek -- "$HANDOFF"; echo "$RC $(calls) $(line IMPLEMENTER_FALLBACK)")"

echo "== 15. 402: out of balance -> Haiku, before the rate-limit check =="
for env in "$BAL_NUM" "$BAL_STR"; do
  reset "$env" "$DONE"
  printf '1\n' >"$FAKE_DIR/rc.1"
  # The error on stderr too: the rate-limit check matches `quota` there, which is
  # why balance is decided first.
  printf '%s\n' 'API Error: 402 {"error":{"message":"Insufficient Balance","type":"insufficient_quota"}}' >"$FAKE_DIR/err.1"
  run IMPLEMENTER_PRIMARY=deepseek -- "$HANDOFF"
  check "402 ($(python3 -c 'import json,sys; print(type(json.loads(sys.argv[1])["api_error_status"]).__name__)' "$env")): switched" \
    "0 2 deepseek -> haiku (balance)" "$RC $(calls) $(line IMPLEMENTER_FALLBACK)"
  check "402: told why" yes "$(has "out of balance" "$(cat "$FAKE_DIR/prompt.2")")"
  check "402: the primary's pass costs nothing it can price" "deepseek:$(call_field 1 sid) COST_USD=0 COST_BASIS=thread" "$(line IMPLEMENTER_FALLBACK_FROM)"
done
reset "$BAL_NUM" "$DONE"
printf '1\n' >"$FAKE_DIR/rc.1"
run IMPLEMENTER_PRIMARY=deepseek -- --resume deepseek:11111111-2222-3333-4444-555555555555 "$HANDOFF"
check "402 on a resumed primary thread: a fresh Haiku pass" "0 2 claude-haiku-5-5 " \
  "$RC $(calls) $(call_field 2 model) $(call_field 2 resume)"
reset "$BAL_NUM" "$DONE"
printf '1\n' >"$FAKE_DIR/rc.1"
run IMPLEMENTER_PRIMARY=deepseek IMPLEMENTER_FALLBACK=none -- "$HANDOFF"
check "402, fallback off: exit 76, balance" "76 1 balance (deepseek)" "$RC $(calls) $(line IMPLEMENTER_RESULT)"
reset "$BAL_NUM" "$DONE"
printf '1\n' >"$FAKE_DIR/rc.1"
run -- --resume deepseek:11111111-2222-3333-4444-555555555555 "$HANDOFF"
check "402 on a secondary thread (Haiku primary): no switch back" "76 1 balance (deepseek)" "$RC $(calls) $(line IMPLEMENTER_RESULT)"

echo "== 16. 429 and 503 stop as a rate limit, never switch =="
for env in "$LIMITED" "$OVER_NUM" "$OVER_STR" '{"type":"result","is_error":true,"api_error_status":"429","result":"API Error: 429","session_id":"SID"}'; do
  reset "$env" "$DONE"
  printf '1\n' >"$FAKE_DIR/rc.1"
  run IMPLEMENTER_PRIMARY=deepseek -- "$HANDOFF"
  check "$(python3 -c 'import json,sys; print(repr(json.loads(sys.argv[1])["api_error_status"]))' "$env"): exit 75, one call" \
    "75 1 rate_limited (exit 1)" "$RC $(calls) $(line IMPLEMENTER_RESULT)"
done

echo "== 17. another API error stays an error: no switch =="
reset "$BAD_REQ" "$DONE"
printf '1\n' >"$FAKE_DIR/rc.1"
run IMPLEMENTER_PRIMARY=deepseek -- "$HANDOFF"
check "400: exit 1, one call, error" "1 1 error (exit 1)" "$RC $(calls) $(line IMPLEMENTER_RESULT)"

echo "== 18. no switch back from the secondary =="
reset "$REFUSAL" "$DONE"
run IMPLEMENTER_PRIMARY=deepseek -- --resume haiku:aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee "$HANDOFF"
check "a resumed Haiku thread (DeepSeek primary) that refuses: exit 76, one call" "76 1 flagged (haiku)" \
  "$RC $(calls) $(line IMPLEMENTER_RESULT)"
reset "$DS_REFUSAL" "$DONE"
run IMPLEMENTER_PRIMARY=deepseek -- --resume deepseek:11111111-2222-3333-4444-555555555555 "$HANDOFF"
check "a resumed primary DeepSeek thread that refuses falls back" "0 2 claude-haiku-5-5" "$RC $(calls) $(call_field 2 model)"
reset "$DECLINED" "$DONE"
run IMPLEMENTER_PRIMARY=deepseek -- --resume deepseek:11111111-2222-3333-4444-555555555555 "$HANDOFF"
check "a resumed primary DeepSeek thread that declines falls back" "0 2 deepseek -> haiku (declined)" "$RC $(calls) $(line IMPLEMENTER_FALLBACK)"

echo "== 19. settings are validated before any call =="
reset "$DONE"
run IMPLEMENTER_PRIMARY=Deepseek -- "$HANDOFF"
check "unknown primary: exit 1, no call" "1 0" "$RC $(calls)"
check "unknown primary: says why" yes "$(has "IMPLEMENTER_PRIMARY must be haiku or deepseek" "$OUT")"
run IMPLEMENTER_FALLBACK=yes -- "$HANDOFF"
check "unknown fallback value: exit 1, no call" "1 0" "$RC $(calls)"
for v in on deepseek haiku; do
  reset "$REFUSAL" "$DONE"
  run IMPLEMENTER_FALLBACK=$v -- "$HANDOFF"
  check "IMPLEMENTER_FALLBACK=$v means on" "0 2" "$RC $(calls)"
done
reset "$REFUSAL" "$DONE"
run IMPLEMENTER_FALLBACK= -- "$HANDOFF"
check "IMPLEMENTER_FALLBACK empty means off" "76 1" "$RC $(calls)"

echo "== 20. effort: a stray CLAUDE_CODE_EFFORT_LEVEL never reaches a pass =="
reset "$DONE"
run CLAUDE_CODE_EFFORT_LEVEL=max -- "$HANDOFF"
check "haiku pass: stripped, --effort xhigh" " xhigh" "$(call_field 1 cel) $(call_field 1 effort)"
reset "$DS_DONE"
run IMPLEMENTER_PRIMARY=deepseek CLAUDE_CODE_EFFORT_LEVEL=max -- "$HANDOFF"
check "deepseek pass, no DEEPSEEK_EFFORT: stripped, no flag" " " "$(call_field 1 cel) $(call_field 1 effort)"
reset "$DS_DONE"
run IMPLEMENTER_PRIMARY=deepseek CLAUDE_CODE_EFFORT_LEVEL=max DEEPSEEK_EFFORT=low -- "$HANDOFF"
check "deepseek pass with DEEPSEEK_EFFORT: only --effort carries it" " low" "$(call_field 1 cel) $(call_field 1 effort)"
run IMPLEMENTER_DRY_RUN=1 -- "$HANDOFF"
check "dry run shows the strip" yes "$(has "-u CLAUDE_CODE_EFFORT_LEVEL" "$OUT")"

echo "== 21. --max-budget-usd on Haiku passes only =="
reset "$DS_REFUSAL" "$DONE"
run IMPLEMENTER_PRIMARY=deepseek IMPLEMENTER_MAX_BUDGET_USD=2 -- "$HANDOFF"
check "deepseek pass: no budget; haiku fallback: budget" " 2" "$(call_field 1 budget) $(call_field 2 budget)"

echo "== 22. --smoke tests the primary =="
run IMPLEMENTER_PRIMARY=deepseek IMPLEMENTER_DRY_RUN=1 -- --smoke
check "smoke on deepseek" yes "$(has "--bare" "$OUT")"
run IMPLEMENTER_DRY_RUN=1 -- --smoke
check "smoke on haiku by default" yes "$(has "--safe-mode" "$OUT")"

echo "== 23. the cost rollup (lib/cost-rollup.py) =="
J="$TMP/journal.md"
cat >"$J" <<'JR'
## t — ORCHESTRATOR dispatch g1 r0 BASE_SHA=x THREAD_ID=- SESSION_ID=-
## t — ORCHESTRATOR ids g1 r0 THREAD_ID=deepseek:a SESSION_ID=-
## t — ORCHESTRATOR implemented g1 r0 STATUS=DONE MODEL=deepseek-flash COST_USD=0.10 COST_BASIS=thread
## t — ORCHESTRATOR dispatch g1 r1 BASE_SHA=x THREAD_ID=deepseek:a SESSION_ID=s
## t — ORCHESTRATOR implemented g1 r1 STATUS=DONE MODEL=deepseek-flash COST_USD=0.25 COST_BASIS=thread
## t — ORCHESTRATOR dispatch g1 r2 BASE_SHA=x THREAD_ID=deepseek:a SESSION_ID=s
## t — ORCHESTRATOR ids g1 r2 THREAD_ID=haiku:b SESSION_ID=s
## t — ORCHESTRATOR implemented g1 r2 STATUS=DONE MODEL=claude-haiku-5-5 FALLBACK=(deepseek -> haiku (balance)) COST_USD=0.40 COST_BASIS=thread FROM=deepseek:a FROM_COST_USD=0.0 FROM_COST_BASIS=thread
## t — ORCHESTRATOR dispatch g2 r0 BASE_SHA=x THREAD_ID=- SESSION_ID=-
## t — ORCHESTRATOR ids g2 r0 THREAD_ID=haiku:c SESSION_ID=-
## t — ORCHESTRATOR implemented g2 r0 STATUS=DONE MODEL=claude-haiku-5-5 COST_USD=0.05
## t — ORCHESTRATOR implemented g2 r1 STATUS=DONE MODEL=claude-haiku-5-5 COST_USD=0.08
## t — ORCHESTRATOR implemented g3 r0 STATUS=DONE MODEL=x COST_USD=0.01 COST_BASIS=pass
## t — ORCHESTRATOR implemented g3 r1 STATUS=DONE MODEL=x COST_USD=0.02 COST_BASIS=pass
## t — ORCHESTRATOR dispatch g4 r0 BASE_SHA=x THREAD_ID=haiku:d SESSION_ID=-
## t — ORCHESTRATOR implemented g4 r0 STATUS=DONE MODEL=x COST_USD=0.05
## t — ORCHESTRATOR dispatch g4 r1 BASE_SHA=x THREAD_ID=deepseek:e SESSION_ID=-
## t — ORCHESTRATOR implemented g4 r1 STATUS=DONE MODEL=x COST_USD=0.07
## t — ORCHESTRATOR ids g5 r0 THREAD_ID=haiku:p SESSION_ID=-
## t — ORCHESTRATOR implemented g5 r0 STATUS=DONE MODEL=x COST_USD=0.03
## t — ORCHESTRATOR dispatch g5 r0 BASE_SHA=y THREAD_ID=- SESSION_ID=-
## t — ORCHESTRATOR implemented g5 r0 STATUS=DONE MODEL=x COST_USD=0.02
JR
roll="$(python3 "$HOUSE/scripts/lib/cost-rollup.py" "$J")"
check "a dispatch-only fix round joins its thread; a low FROM keeps the thread's max; threads add" \
  "g1	0.650000	2" "$(grep '^g1' <<<"$roll")"
check "no basis reads as thread (the latest running total)" "g2	0.080000	1" "$(grep '^g2' <<<"$roll")"
check "pass basis sums" "g3	0.030000	1" "$(grep '^g3' <<<"$roll")"
check "threads named on dispatch lines only (no ids line) stay apart" "g4	0.120000	2" "$(grep '^g4' <<<"$roll")"
check "a new attempt (dispatch r0, no thread) does not join the old thread" "g5	0.050000	2" "$(grep '^g5' <<<"$roll")"
check "total" "TOTAL	0.930000	-" "$(grep '^TOTAL' <<<"$roll")"
check "one goal asked for" "g2	0.080000	1" "$(python3 "$HOUSE/scripts/lib/cost-rollup.py" "$J" g2 | head -n1)"

if [[ "$fails" -eq 0 ]]; then
  echo "implement-test: all passed"
else
  echo "implement-test: $fails failed"
  exit 1
fi
