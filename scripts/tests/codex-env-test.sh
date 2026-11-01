#!/usr/bin/env bash
# Self-test: the legacy IMPLEMENTER=codex launcher (deepseek-code.sh) starts
# Codex without the house's CW_* settings or credential-named variables
# (FUTURE-WORK item 28): Codex's shell tool inherits Codex's environment. Codex
# is a stub that records its environment; nothing calls a model.
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/cw-codex-env-XXXXXX")"
export TMPDIR="$TMP"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
mkdir -p "$HOME"
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

cat >"$TMP/codex" <<'STUB'
#!/usr/bin/env bash
env >"$CODEX_ENV_OUT"
cat >/dev/null
printf '%s\n' '{"type":"thread.started","thread_id":"t-stub"}'
STUB
chmod +x "$TMP/codex"

mkdir -p "$TMP/repo" && cd "$TMP/repo"
git init -q && git -c user.name=t -c user.email=t@t -c commit.gpgSign=false commit -q --allow-empty -m base
printf '# Handoff: g1-a\n' >"$TMP/handoff.md"

env CODEX_BIN="$TMP/codex" CODEX_ENV_OUT="$TMP/env.out" DEEPSEEK_API_KEY=stub-deepseek \
  CW_PROOF_DEPS=/x CW_SOME_WALK_SETTING=1 ANTHROPIC_API_KEY=stub-anthropic ANTHROPIC_BASE_URL=http://x \
  MY_SERVICE_TOKEN=stub DB_PASSWORD=stub PLAIN_SETTING=visible KEYBOARD_LAYOUT=us \
  "$HERE/deepseek-code.sh" "$TMP/handoff.md" >"$TMP/out" 2>&1 || true

seen() { grep -q "^$1=" "$TMP/env.out" && echo present || echo absent; }
check "codex was started" yes "$([[ -s "$TMP/env.out" ]] && echo yes || echo "no: $(tail -3 "$TMP/out")")"
check "CW_* settings hidden" "absent absent 0" \
  "$(seen CW_PROOF_DEPS) $(seen CW_SOME_WALK_SETTING) $(grep -c '^CW_' "$TMP/env.out" || true)"
check "other credentials hidden" "absent absent absent" \
  "$(seen ANTHROPIC_API_KEY) $(seen MY_SERVICE_TOKEN) $(seen DB_PASSWORD)"
check "ANTHROPIC_BASE_URL hidden" absent "$(seen ANTHROPIC_BASE_URL)"
check "DEEPSEEK_API_KEY kept (Codex's env_key)" present "$(seen DEEPSEEK_API_KEY)"
check "ordinary variables kept" "present present" "$(seen PLAIN_SETTING) $(seen KEYBOARD_LAYOUT)"
check "CODEX_HOME kept" present "$(seen CODEX_HOME)"
# The key Codex keeps is kept from its shell tool by its own config.
cfg="$HOME/.cache/claude-coding-workflow/codex/config.toml"
check "Codex's shell excludes DEEPSEEK_API_KEY (config)" yes \
  "$(awk '/^\[/{sec=$0} sec=="[shell_environment_policy]" && /^exclude = \["DEEPSEEK_API_KEY"\]$/{f=1} END{print f ? "yes" : "no"}' "$cfg")"

echo
if [[ "$fails" -eq 0 ]]; then
  echo "codex-env-test: all passed"
else
  echo "codex-env-test: $fails failed"
  exit 1
fi
