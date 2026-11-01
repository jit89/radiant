#!/usr/bin/env bash
# Self-test: install.sh --always-on (docs/features/always-on step 15; slice
# 4b): the two LaunchAgent plists (valid, the right programs, the update
# switches, an absolute PATH), the ~/.config/cw-always-on/ skeleton (0700, a
# notify.conf template 0600 that a rerun keeps), and nothing loaded.
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/cw-ao-install-XXXXXX")"
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

export CW_AO_HOME="$TMP/aohome" CW_AO_CACHE="$TMP/aocache" CW_AO_LAUNCH_AGENTS="$TMP/agents"
mkdir -p "$TMP/bin"
printf '#!/usr/bin/env bash\necho "$*" >>"%s/launchctl"\n' "$TMP" >"$TMP/bin/launchctl"
chmod +x "$TMP/bin/launchctl"
PATH="$TMP/bin:$PATH" bash "$HERE/install.sh" --always-on >"$TMP/out"
SUP="$CW_AO_LAUNCH_AGENTS/com.cw.always-on.plist"
BEAT="$CW_AO_LAUNCH_AGENTS/com.cw.always-on.heartbeat.plist"
get() { plutil -extract "$2" raw -o - "$1" 2>/dev/null || echo "-"; }
check "both plists written and valid" "OK OK" \
  "$(plutil -lint "$SUP" | awk '{print $NF}') $(plutil -lint "$BEAT" | awk '{print $NF}')"
check "the supervisor: caffeinate -is cw-supervisor.sh, at load, kept alive, Standard" \
  "/usr/bin/caffeinate -is $HERE/cw-supervisor.sh true true Standard" \
  "$(get "$SUP" ProgramArguments.0) $(get "$SUP" ProgramArguments.1) $(get "$SUP" ProgramArguments.2) $(get "$SUP" RunAtLoad) $(get "$SUP" KeepAlive) $(get "$SUP" ProcessType)"
check "the heartbeat: cw-decide.sh heartbeat at 09:00" "$HERE/cw-decide.sh heartbeat 9 0" \
  "$(get "$BEAT" ProgramArguments.0) $(get "$BEAT" ProgramArguments.1) $(get "$BEAT" StartCalendarInterval.Hour) $(get "$BEAT" StartCalendarInterval.Minute)"
for p in "$SUP" "$BEAT"; do
  path="$(get "$p" EnvironmentVariables.PATH)"
  check "$(basename "$p"): the update switches; a PATH of absolute folders with /usr/bin and Homebrew" "1 1 yes yes yes" \
    "$(get "$p" EnvironmentVariables.DISABLE_UPDATES) $(get "$p" EnvironmentVariables.DISABLE_AUTOUPDATER) $(tr ':' '\n' <<<"$path" | grep -qv '^/' && echo no || echo yes) $(tr ':' '\n' <<<"$path" | grep -qx /usr/bin && echo yes || echo no) $(tr ':' '\n' <<<"$path" | grep -qx /opt/homebrew/bin && echo yes || echo no)"
  check "  ...its logs in the cache folder, which exists" "yes yes yes" \
    "$([[ "$(get "$p" StandardOutPath)" == "$CW_AO_CACHE"/* ]] && echo yes || echo no) $([[ "$(get "$p" StandardErrorPath)" == "$CW_AO_CACHE"/* ]] && echo yes || echo no) $([[ -d "$CW_AO_CACHE" ]] && echo yes || echo no)"
done
check "the skeleton: 0700 folders, a notify.conf template 0600" "700 700 700 600 yes" \
  "$(stat -f %Lp "$CW_AO_HOME") $(stat -f %Lp "$CW_AO_HOME/state") $(stat -f %Lp "$CW_AO_HOME/attempts") $(stat -f %Lp "$CW_AO_HOME/notify.conf") $(grep -qx 'recipient=' "$CW_AO_HOME/notify.conf" && echo yes || echo no)"
check "nothing loaded" no "$([[ -e "$TMP/launchctl" ]] && echo yes || echo no)"
printf 'recipient=+15550000000\n' >"$CW_AO_HOME/notify.conf"
chmod 644 "$CW_AO_HOME/notify.conf"
bash "$HERE/install.sh" --always-on >/dev/null
check "a rerun keeps the filled notify.conf, and makes it 0600 again" "recipient=+15550000000 600" "$(cat "$CW_AO_HOME/notify.conf") $(stat -f %Lp "$CW_AO_HOME/notify.conf")"

echo
if [[ "$fails" -eq 0 ]]; then
  echo "always-on-install-test: all passed"
else
  echo "always-on-install-test: $fails failed"
  exit 1
fi
