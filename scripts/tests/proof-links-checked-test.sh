#!/usr/bin/env bash
# Self-test: PROOF_ROOT_LINKS_CHECKED (lib/proof.sh). A caller that walked the
# root for hard links already (the mutation step, after a clone's baseline) may
# skip that walk for one call; the run's TMP is still walked, and a value
# inherited from the environment never skips anything.
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/cw-links-XXXXXX")"; TMP="$(cd "$TMP" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT
fails=0
check() { if [[ "$2" == "$3" ]]; then echo "  ok   $1"; else echo "  FAIL $1: want [$2] got [$3]"; fails=$((fails + 1)); fi; }
export PROOF_ROOT_LINKS_CHECKED=1   # inherited: must be ignored once proof.sh is sourced
# shellcheck disable=SC1091
source "$HERE/lib/git-guard.sh"
# shellcheck disable=SC1091
source "$HERE/lib/proof.sh"
mkdir -p "$TMP/root" "$TMP/out" "$TMP/t1" "$TMP/t2" "$TMP/t3" "$TMP/t4"
echo secret >"$TMP/out/secret"
ln "$TMP/out/secret" "$TMP/root/leak"
git -C "$TMP/root" init -q
run() { PROOF_SANDBOX_REASON=""; set +e; "$@"; set -e; echo "${PROOF_SANDBOX_REASON:-none}"; }
check "an inherited value is ignored: the root's link refused" proof-hardlink \
  "$(PROOF_ROOT="$TMP/root" PROOF_WALK="$TMP/root/.git" run proof_exec 30 "$TMP/o1" "$TMP/t1" true)"
check "unset: the root's link refused" proof-hardlink \
  "$(PROOF_ROOT="$TMP/root" PROOF_WALK="$TMP/root/.git" PROOF_ROOT_LINKS_CHECKED=0 run proof_exec 30 "$TMP/o2" "$TMP/t2" true)"
check "checked: the root's walk skipped" none \
  "$(PROOF_ROOT="$TMP/root" PROOF_WALK="$TMP/root/.git" PROOF_ROOT_LINKS_CHECKED=1 run proof_exec 30 "$TMP/o3" "$TMP/t3" true | tail -n1 | grep -v proof-hardlink || echo proof-hardlink)"
ln "$TMP/out/secret" "$TMP/t4/leak"
check "checked: a link in the run's TMP still refused" proof-hardlink \
  "$(PROOF_ROOT="$TMP/root" PROOF_WALK="$TMP/root/.git" PROOF_ROOT_LINKS_CHECKED=1 run proof_exec 30 "$TMP/o4" "$TMP/t4" true)"
if [[ "$fails" -eq 0 ]]; then echo "proof-links-checked: OK"; else echo "proof-links-checked: $fails FAILURE(S)" >&2; exit 1; fi
