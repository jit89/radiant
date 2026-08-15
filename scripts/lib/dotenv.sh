# shellcheck shell=bash
# Read KEY=value from a dotenv file without executing it.
# Last matching line wins. Optional surrounding quotes are stripped.

env_file_get() {
  local file="$1" key="$2" line val
  [[ -f "$file" ]] || return 1
  line="$(grep -E "^${key}=" "$file" | tail -n1)" || return 1
  [[ -n "$line" ]] || return 1
  val="${line#*=}"
  val="${val%$'\r'}"
  if [[ ${#val} -ge 2 && "$val" == \"*\" ]]; then
    val="${val:1:${#val}-2}"
  elif [[ ${#val} -ge 2 && "$val" == \'*\' ]]; then
    val="${val:1:${#val}-2}"
  fi
  printf '%s' "$val"
}

# Load VAR from the first file in the remaining args that defines it.
# Does nothing if VAR is already set and non-empty.
load_key_from_files() {
  local var="$1" f val
  shift
  if [[ -n "${!var:-}" ]]; then
    return 0
  fi
  for f in "$@"; do
    val="$(env_file_get "$f" "$var" || true)"
    if [[ -n "$val" ]]; then
      printf -v "$var" '%s' "$val"
      export "$var"
      return 0
    fi
  done
  return 1
}

# Transport rate-limit: process failed AND (stderr says so OR the Claude
# JSON envelope is an API 429 / session-limit). Never grep model verdict
# prose — only stderr and envelope fields (api_error_status, is_error,
# terminal_reason, and result when is_error is true).
is_transport_rate_limit() {
  local rc="$1" err="$2" json="${3:-}"
  [[ "$rc" -ne 0 ]] || return 1
  if [[ -f "$err" ]] && \
     grep -qiE '429|rate.?limit|overloaded|quota|too many requests|insufficient.?quota|session limit' "$err"
  then
    return 0
  fi
  [[ -n "$json" && -f "$json" ]] || return 1
  python3 - "$json" <<'PY'
import json, sys
try:
    obj = json.loads(open(sys.argv[1], encoding="utf-8").read())
except (OSError, json.JSONDecodeError):
    sys.exit(1)
if not isinstance(obj, dict):
    sys.exit(1)
status = obj.get("api_error_status")
if status == 429 or status == "429":
    sys.exit(0)
if obj.get("is_error") or obj.get("terminal_reason") == "api_error":
    text = str(obj.get("result") or "")
    low = text.lower()
    for n in ("429", "rate limit", "rate-limit", "session limit", "overloaded",
              "too many requests", "insufficient quota"):
        if n in low:
            sys.exit(0)
sys.exit(1)
PY
}
