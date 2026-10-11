# Plan: Temp-file hygiene
_Locked via crucible — by Claude + cobalt. Revised after Grok rounds 1-2; APPROVED in round 3._

## Goal

The house stops leaking temp files and stops losing wake evidence. Today
nothing it writes to `$TMPDIR` is removed except a succeeded goal's run
folder: 2,294 `run-goal-*` folders, 1,021 `claude-implement-raw-*`, 688
`claude-goal-*`, 560 `grok-review-*`, 251 `run-goals-*` (~76 MB), almost all
from the test suite driving the real scripts. Half the `grok-review` files
are world-readable. And the one thing that must survive, a woken goal's run
folder (stop file, diff, proof output, verdict), lives where macOS deletes
it after ~3 idle days or at reboot. After this change: tests write only
inside their own temp folder; launcher output lives in a folder its caller
owns and deletes; wake evidence and Grok verdicts live under
`~/.cache/claude-coding-workflow/` and are pruned past 14 days.

## Approach

1. **Caller-owned output folder (`CW_OUT_DIR`).** `claude-implement.sh`,
   `claude-goal-review.sh` and `grok-review.sh` write every file they create
   (raw JSON, `.err`, report / verdict) into `$CW_OUT_DIR` when it is set.
   Unset, each makes its own folder:
   - `claude-implement.sh`, `claude-goal-review.sh` (incl. `--smoke`):
     `mktemp -d ~/.cache/claude-coding-workflow/runs/<launcher>-XXXXXX`.
   - `grok-review.sh` (incl. `--oracle`, `--smoke`): files go straight into
     `~/.cache/claude-coding-workflow/grok/`, named as today
     (`grok-review-<sid>-<ts>.md`, raw beside it).
   Before any `mktemp` there, a shared helper creates
   `~/.cache/claude-coding-workflow`, `runs/` and `grok/` and sets each to
   0700 (`mkdir -p` alone neither creates them on a fresh machine before a
   `mktemp -d` under `set -e`, nor tightens the cache root, which
   `git_meta_init` leaves 0755 today).
   The existing explicit overrides `GROK_REVIEW_OUT` and `CLAUDE_REVIEW_OUT`
   still win for the verdict path. A bare `OUT` is not one (both scripts
   assign it) and stays ignored; the stale header comment naming it is
   corrected. Printed result lines
   (`VERDICT_FILE:`, `REPORT:`, `LOG:`, `stderr:`) keep their names and point
   at the new paths.
2. **Raw output dropped only where no caller can still need it.**
   - **Under `CW_OUT_DIR`** (a `run-goal.sh` pass) a launcher deletes
     nothing. `ok` is a transport result, not a successful goal: the
     implementer reports `ok` for `BLOCKED` / `MISSING`, and `run-goal.sh`
     may still wake on that pass (blocked, proof-red, dirty tree, tamper, a
     review failure) with a stop file naming `LOG:` and `stderr:`. The
     folder's owner decides: `succeed` removes `RUN_DIR`, a wake keeps it.
   - **Standalone** (Grok from the Architect, a smoke run) the launcher
     deletes its raw JSON and `.err` when the result is `ok`, unless
     `CW_KEEP_RAW=1`; any other result keeps both, and the parsed verdict /
     report is never deleted. No printed line names a deleted file (`LOG:` /
     `stderr:` print `(removed)`).
   - **Every** raw and `.err` a launcher creates is tracked in a list, not
     one variable: the implementer's unsaved-thread retry and DeepSeek
     fallback, and the reviewer's flagged-retry loop, each make a new pair
     and today drop the pointer to the old one. Deletion (standalone `ok`
     only) runs after `usage_lines` has read the envelope, so
     `IMPLEMENTER_COST_USD` is never lost.
3. **`run-goal.sh` owns its run folder under `~/.cache`.** `RUN_DIR` becomes
   `mktemp -d "$HOME/.cache/claude-coding-workflow/runs/run-goal-<id>-XXXXXX"`
   (0700), and the script exports `CW_OUT_DIR="$RUN_DIR"` to the implementer
   and reviewer launchers. Success removes `RUN_DIR` as today (the
   `*/run-goal-*` guard and `KEEP_RUN_DIR` unchanged); a wake keeps it, now
   with the launchers' files beside `stop.md`. The reviewer's
   `--add-dir "$RUN_DIR"` and the implementer's handoff grant (the handoff
   lives in `RUN_DIR`) already follow the variable.
4. **`run-goals.sh` stop and stuck folders** (`run-goals-stop-*`,
   `run-goals-stuck-*`, which hold the walker's own stop files) move to
   `~/.cache/claude-coding-workflow/runs/` too. Its short-lived pointer and
   journal-expect files stay in `$TMPDIR` (already removed by trap).
5. **14-day prune.** A helper `scripts/lib/prune.sh` (`cw_prune`) deletes
   top-level entries of `~/.cache/claude-coding-workflow/runs/` and
   `.../grok/` whose mtime is older than 14 days (`CW_PRUNE_DAYS` overrides;
   `0` disables). It is rooted at those two directories only and touches
   nothing beside them (`keys/`, `logs/`, `codex/`, `git-meta-*.txt`, the
   `run-goal-<id>/` ART_DIRs). A missing directory is success. Called at the
   start of `run-goal.sh`, `run-goals.sh` and `grok-review.sh`; it never
   fails the caller (`|| true` under `set -e`).
6. **Private files.** Every output file (raw, `.err`, report / verdict) is
   **pre-created** 0600 — `(umask 077; : >"$f")` in a subshell, or `mktemp`,
   which makes 0600 files — and the launcher then redirects onto the
   existing file, which keeps its mode. The launcher's own umask never
   changes: it is inherited by the implementer, and 077 there would make the
   target repo's new files 0600. Folders are made by `mktemp -d` (0700).
7. **`mktemp` templates.** Every `mktemp -t name-XXXXXX.ext` becomes
   `mktemp "<dir>/name-XXXXXX"` (BSD `-t` treats the template as a prefix),
   in the three launchers, `install.sh` (`grok-rl`, `grok-ok`) and the legacy
   `deepseek-code.sh`. In `deepseek-code.sh` (`IMPLEMENTER=codex`, legacy)
   additionally: the prompt file is removed once the `codex exec` it fed has
   returned (the dry-run path prints `PROMPT_FILE:` and exits first, so it
   keeps it); a jsonl and its `.err` are removed only for an attempt the
   rate-limit loop is about to retry. The last attempt's pair is kept: the
   caller tails its `.err` and `emit_and_exit` prints both paths after
   `codex_once` returns (`deepseek-code.sh:352-354`, `:388`, `:508`). Its report and return handoff
   stay in `$TMPDIR` (see Key decisions).
8. **Tests.** Every `scripts/tests/*-test.sh` exports, at the top, both
   `TMPDIR="$TMP"` and `HOME="$TMP/home"` for the whole script, not per
   call (`grok-review-test.sh` sets `HOME` on one oracle call only, so its
   `review()` runs would prune and write under the real
   `~/.cache/claude-coding-workflow`). Existing exit traps are kept as they
   are: `proof-test.sh` and `signal-test.sh` already `trap cleanup EXIT`,
   which also kills their children. A test that reads something from the
   real home first copies it into `$TMP/home`. New assertions: each launcher
   honours `CW_OUT_DIR` and deletes nothing under it; standalone, raw/`.err`
   are gone after `ok`, kept after `error`, kept with `CW_KEEP_RAW=1`, and
   every retry's pair is tracked (none orphaned); `IMPLEMENTER_COST_USD`
   survives deletion; output files are 0600 while a file the implementer
   stub creates in the repo is not; `runs/`, `grok/` and the cache root are
   0700 both on a fresh `HOME` and when the cache root, `runs/` and `grok/`
   already exist at 0755 (as `git_meta_init` leaves the root on every
   machine today); a wake's `RUN_DIR` is under
   `$HOME/.cache/claude-coding-workflow/runs/`, holds the launcher files, and
   the reviewer's `--add-dir` names it; the prune deletes an entry aged 15
   days, keeps one aged 13 days, succeeds on a missing directory, and never
   touches `keys/`, a `git-meta-*.txt` or an ART_DIR.
9. **Suite guard.** A new `scripts/tests/tmp-hygiene-test.sh` runs every
   other test script with a fresh `TMPDIR` parent and a private `HOME`, and
   fails if anything is left in that `TMPDIR` afterwards or if the real
   `~/.cache/claude-coding-workflow` listing (names and mtimes) changed, so a
   future test that forgets either export fails. `install.sh --check` lists
   it like the others.
10. **Clear the leftovers once.** After the change lands, and only when no
    house launcher or test is live (`pgrep -f` on
    `claude-coding-workflow/scripts/`, with its own line excluded, and
    checked by hand), the Architect deletes from the real `$TMPDIR` only
    entries matching the house prefixes (`run-goal-*`, `run-goals-*`,
    `claude-implement-raw-*`, `claude-goal-*`, `grok-review-*`, `grok-rl-*`,
    `grok-ok-*`, `cw-*`, `deepseek-*`) **and** older than one day, listing
    counts before and after in the journal. No script does this; it is a
    one-off.
11. **Docs.** `CLAUDE.md` (where verdicts and stop files live), the launcher
    headers, `README.md` and `GLOSSARY.md` if a term changes; FUTURE-WORK
    item 4 marked done.

## Key decisions & tradeoffs

- **Caller owns the folder, not the launcher (Q1).** A launcher deleting its
  own output on exit would delete what `run-goal.sh` reads next and what a
  wake's stop file points at. Cost: one env var every launcher must honour.
- **Wake evidence in `~/.cache`, not `$TMPDIR` (Q2).** macOS removes idle
  `$TMPDIR` files after ~3 days; a wake read after a weekend could have lost
  its reason. Cost: the reviewer's and implementer's grants now point under
  `~/.cache`, beside `keys/`, which stays in the implementer's `denyRead`.
- **Prune by mtime, 14 days, at run start.** No daemon, no cron. A folder
  is pruned whatever its goal's state; 14 days is far past any wake the
  Architect would still act on, and the journal and events index keep the
  summary.
- **A launcher deletes raw only standalone, and only on `ok`.** Under
  `run-goal.sh` the run folder's owner decides, because `ok` does not mean
  the goal will not wake. Standalone, the raw envelope matters only when
  parsing or the turn went wrong; on `ok` the parsed verdict holds the
  content.
- **The legacy Codex launcher keeps its report and return handoff in
  `$TMPDIR`.** Codex writes the return handoff itself, inside its
  `workspace-write` sandbox, which allows `$TMPDIR` but not `~/.cache`;
  moving it into `RUN_DIR` would mean adding a writable root to that
  sandbox. `IMPLEMENTER=codex` is the legacy path until the Claude
  launcher's fallback has shipped goals, so a Codex wake read after ~3 idle
  days may still have lost its report. Only its retry leak is fixed.
- **Tests isolate `TMPDIR` and `HOME` rather than the scripts learning a
  test mode.** No production branch exists only for tests.

## Assumptions

1. Most leftovers come from the tests — measured: 2,146 of 2,294
   `run-goal-*` folders hold a `stop.md`, from faked wakes.
2. All 19 tests remove their own `TMP` on exit (17 by `rm -rf`, two by a
   `cleanup` that also kills children); none set `TMPDIR`; `HOME` is set
   script-wide in most, but only per call in some (`grok-review-test.sh`).
3. Callers read launcher output after the launcher exits
   (`run-goal.sh:782-984`, `claude-implement.sh:330-345`), and a result of
   `ok` can still end in a wake (`claude-implement.sh:297-302`).
4. A resume does not need the old `RUN_DIR`; it makes a new one, and pending
   fix handoffs and verdicts are in `ART_DIR` (`run-goal.sh:568-571`, `:734`).
5. macOS clears `$TMPDIR` entries idle ~3 days and at reboot (convention).
6. Half the `grok-review` files are 0644; launchers set no umask.
7. BSD `mktemp -t` treats `XXXXXX.ext` templates as a prefix.
8. The reviewer reads `RUN_DIR` via an explicit `--add-dir`; the implementer
   via the handoff folder; `~/.cache/claude-coding-workflow/keys` is in the
   implementer's `denyRead` (`claude-implement.sh:161-218`). This holds for
   the Claude launcher only; the legacy Codex launcher reads its handoff
   through Codex's own sandbox and writes to `$TMPDIR`.
9. `~/.cache/claude-coding-workflow` is 0755 today (`git-guard.sh:46-48`
   creates it with the process umask).

## Risks / open questions

- **The implementer can write in `RUN_DIR` during its pass** (it is the
  handoff folder, an `--add-dir` grant). With `CW_OUT_DIR=RUN_DIR`, launcher
  files land in a folder the implementer could edit. Today it can already
  edit `goals-base.md`, which `run-goal.sh` re-reads after the pass
  (`:770`, `:868`). Not widened in a way that matters for the implementer's
  own files (it could forge only its own report, which the proof and the
  reviewer still gate); the reviewer's files are written after the
  implementer has exited. Recorded for item 7 / the parallel walker, not
  fixed here.
- **`~/.cache` growth between runs** is bounded only by the prune at the next
  run; a house unused for months keeps its last wakes, which is intended.
- **Sandbox path change.** Proven by a dry run of `claude-implement.sh` and
  `claude-goal-review.sh` with `RUN_DIR` under `~/.cache` before commit.

## Out of scope

- Moving `ART_DIR`, `keys/`, `logs/` or the events index.
- Changing what the implementer's sandbox may read or write.
- The walker's goal logic, `goals.py`, `run-goals` ordering (frozen).
- Cleaning anything outside the house prefixes in `$TMPDIR`.
