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

# Transport rate-limit: only when the process failed AND stderr says so.
# Never grep the model's result text.
is_transport_rate_limit() {
  local rc="$1" err="$2"
  [[ "$rc" -ne 0 ]] || return 1
  [[ -f "$err" ]] || return 1
  grep -qiE '429|rate.?limit|overloaded|quota|too many requests|insufficient.?quota' "$err"
}
