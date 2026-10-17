# cache.sh — where the house keeps files that must outlive a run, and the
# helpers that keep them private and bounded. Sourced, never run.
#
# ~/.cache/claude-coding-workflow/
#   runs/   run-goal folders (a wake's evidence), walker stop folders, and the
#           folders a launcher makes when it runs without CW_OUT_DIR
#   grok/   Grok verdicts and raw output, until the Architect logs them
#   handoffs/  each run's implementer folder (handoffs, return documents, the
#           frozen plan), outside runs/ so runs/ can be denied to it whole
#   deps/   each walk's (or serial run's) dependency folder: worktree_setup
#           writes it, proofs only read it (docs/features/proof-sandbox)
#   tests/  last/: the last full run-all.sh run of a house checkout, keyed by
#           lib/tree-key.py, for install.sh --check to reuse
#   lessons/  the lessons hook's run markers (due/), run locks and logs/
#           (scripts/lessons.py writes and prunes them itself)
# runs/, grok/ and lessons/logs/ are pruned past CW_PRUNE_DAYS (default 14) by
# cw_prune. Nothing else
# under the cache root is touched here: keys/, logs/, codex/, git-meta-*.txt
# and the run-goal-<id>/ artifact folders have owners of their own.

CW_CACHE="$HOME/.cache/claude-coding-workflow"

# cw_cache_init — create the cache root, runs/, grok/ and lessons/ and make each 0700.
# chmod as well as mkdir: git_meta_init creates the root with the process
# umask (0755), and mkdir -p never tightens a folder that exists.
cw_cache_init() {
  local d
  for d in "$CW_CACHE" "$CW_CACHE/runs" "$CW_CACHE/grok" "$CW_CACHE/lessons" "$CW_CACHE/handoffs" "$CW_CACHE/deps"; do
    mkdir -p "$d" && chmod 700 "$d" || return 1
  done
}

# cw_private FILE... — create each FILE empty and 0600 without changing this
# shell's umask (an implementer launched from here inherits it, and 077 would
# make the target repo's new files 0600). A later `>FILE` keeps the mode.
cw_private() {
  (umask 077 && for f in "$@"; do : >"$f"; done)
}

# cw_prune — delete top-level entries of runs/, grok/ and lessons/logs/ whose mtime is older
# than CW_PRUNE_DAYS days (0 disables). A missing folder is success; a failure
# is never the caller's.
cw_prune() {
  local days="${CW_PRUNE_DAYS:-14}" d
  [[ "$days" =~ ^[0-9]+$ ]] || return 0
  [[ "$days" -gt 0 ]] || return 0
  for d in "$CW_CACHE/runs" "$CW_CACHE/grok" "$CW_CACHE/lessons/logs" "$CW_CACHE/handoffs" "$CW_CACHE/deps"; do
    [[ -d "$d" ]] || continue
    find "$d" -mindepth 1 -maxdepth 1 -mtime "+$days" -exec rm -rf {} + 2>/dev/null || true
  done
  return 0
}
