#!/usr/bin/env bash
# always-on-balance.sh — the DeepSeek account balance, a backstop the always-on
# supervisor reads before each walk (docs/features/always-on/PLAN.md step 9;
# never summed into the spend ceilings).
#
# stdout: `BALANCE_USD: <amount>` (exit 0), or `BALANCE: error (<why>)` (exit 1)
# for a missing key, a failed request, or no USD balance in the answer.
# The key is the one claude-implement.sh loads (DEEPSEEK_API_KEY, else the
# house .env); it reaches curl on stdin as a header, never on its command line.
# DEEPSEEK_BALANCE_URL overrides the endpoint (tests).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
HOUSE="$(cd "$HERE/../.." && pwd)"
# shellcheck disable=SC1091
source "$HERE/dotenv.sh"
URL="${DEEPSEEK_BALANCE_URL:-https://api.deepseek.com/user/balance}"

fail() { echo "BALANCE: error ($1)"; exit 1; }
load_key_from_files DEEPSEEK_API_KEY "$HOUSE/.env" || true
[[ -n "${DEEPSEEK_API_KEY:-}" ]] || fail "no DeepSeek key"
body="$(printf 'Authorization: Bearer %s\n' "$DEEPSEEK_API_KEY" |
  curl -sS --max-time 30 -H @- -H 'Accept: application/json' "$URL" 2>/dev/null)" || fail "request failed"
python3 -c '
import json, sys
try:
    d = json.loads(sys.argv[1])
    usd = [b for b in d.get("balance_infos") or [] if b.get("currency") == "USD"]
    amount = float(usd[0]["total_balance"])
except (ValueError, KeyError, IndexError, TypeError, AttributeError):
    print("BALANCE: error (no USD balance in the answer)")
    sys.exit(1)
print(f"BALANCE_USD: {amount}")
' "$body"
