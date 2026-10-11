# Plan Review Log: Temp-file hygiene
Phases 0-1 (recon + interrogation) complete — plan locked with the user. MAX_ROUNDS=3 (one round planned; more only on substantive findings).

## Round 1 — Grok

I'll review the temp-hygiene plan against the repo and domain docs, looking for concrete breaks rather than agreeing with its confidence.The plan is loaded. Next I’ll check domain language and the scripts it changes so the review is tied to the actual code.The plan deletes the wake evidence it says must survive, and its privacy and test steps miss the code paths that actually create the files.

1. **`ok` is not a successful goal, but raw and `.err` are deleted anyway.** `claude-implement.sh` reports `IMPLEMENTER_RESULT: ok` for `BLOCKED` and `MISSING` (`claude-implement.sh` 297–302). `run-goal.sh` then wakes on `implementer-blocked`, `proof-red`, `dirty-tree`, contract tamper, and later review failures, and the stop file records `LOG:` and `stderr:` (`run-goal.sh` 190–191, 798–799, 857–858). Item 2 deletes those files before that decision and prints `(removed)`. A blocked pass is the case that most needs the envelope.
   Fix: when `CW_OUT_DIR` is set, leave every file; `run-goal.sh` already removes `RUN_DIR` only in `succeed`.

2. **The umask recipe cannot make the files 0600 without handing umask 077 to the implementer.** Raw, `.err`, and the verdict are created by redirects on the same simple command that execs the child (`claude-implement.sh` 247–250, `claude-goal-review.sh` 157–159, `grok-review.sh` 158–160 and the later `>"$OUT"` at 193 and 217). A subshell umask does not apply to the parent redirect. Umask set in the parent is inherited by Haiku, so repo files land 0600. The `.err` and verdict redirects are not the `mktemp` call, and those are the 0644 files.
   Fix: pre-create every output file mode 0600, restore the caller umask, then redirect onto the existing fds.

3. **Moving Grok verdicts into `~/.cache` makes 0644 files readable by other users.** `$TMPDIR` is `0700`. `git_meta_init` already does `mkdir -p "$HOME/.cache/claude-coding-workflow"` with the process umask (`git-guard.sh` 46–48), so the cache root stays `0755`, and `mkdir -p` will not tighten it later. Grok verdicts are written straight into a shared `grok/` directory, not a `0700` leaf. Nothing in the plan creates `runs/` or `grok/`, so the first `mktemp -d` on a fresh machine fails under `set -e`.
   Fix: `mkdir -p` then `chmod 700` the cache root, `runs/`, and `grok/` before any `mktemp`, and create the verdict file 0600.

4. **Retry paths orphan the envelope the plan claims to delete.** `run_pass` overwrites `RAW` on the unsaved-thread retry and the DeepSeek fallback (`claude-implement.sh` 488–509). `run_claude`'s `while` loop `continue`s on a flag and the next `mktemp` drops the only pointer to the flagged raw (`claude-goal-review.sh` 157–173). `usage_lines` still reads `RAW` at emit time (`claude-implement.sh` 305–323); deleting it before that drops `IMPLEMENTER_COST_USD` from the journal.
   Fix: keep a list of every raw and `.err`, delete them only after `usage_lines`, and keep the one path printed as `VERDICT_FILE` or `LOG`.

5. **The test story targets the wrong scripts and the suite guard cannot see the new leak.** `proof-test.sh` and `signal-test.sh` already `trap cleanup EXIT` (pkill plus `rm -rf`). Replacing that trap with `trap 'rm -rf "$TMP"'` drops the pkill. Assumption 2 counts `grok-review-test.sh` as isolating `HOME` because of one `HOME=` on a single oracle invocation (line 261). `review()` does not set `HOME` or `TMPDIR`. After this change that test calls `cw_prune` on the real `~/.cache/claude-coding-workflow` and leaves error raws there. `install.sh --check` runs that test. The new guard only inspects `TMPDIR`.
   Fix: keep the existing `cleanup` traps; export `HOME` inside `grok-review-test.sh`; have the guard set a private `HOME` and fail if the real cache directory changes.

6. **Assumption 8 is false for `IMPLEMENTER=codex`.** The handoff grant is Claude's `--add-dir` (`claude-implement.sh` 216–218). `deepseek-code.sh` never receives `RUN_DIR`; its sandbox extra roots are the gitdirs (`compute_git_writable_roots`), and `RETURN_DOC` and `OUT` stay predictable `$TMPDIR` paths (403–404) that a weekend wake still loses. `codex_once` also leaks a new prompt file and jsonl on every retry. Item 7's template-only change leaves that in place while `run-goal.sh` still dispatches this launcher.
   Fix: honor `CW_OUT_DIR` for the Codex prompt, jsonl, report, and return handoff, and add `RUN_DIR` to its readable roots.

7. **The one-off delete can hit a live test directory, and prune can fail the first run.** `pgrep -f` for `grok` matches unrelated Grok processes and often the `pgrep` line itself, and it does not cover a running `scripts/tests/*-test.sh`. Prefix `cw-*` is shared with live test dirs. `cw_prune` on a missing directory returns non-zero; under `set -euo pipefail` that aborts `run-goal.sh` before `mkdir`. A prune rooted at the cache directory, rather than only `runs/` and `grok/`, would also delete `git-meta-*.txt` (the tamper baseline) and `run-goal-<id>/` artifacts, which sit beside those two directories.
   Fix: delete only house names older than a day, after `pgrep` for the launchers and the test scripts; make a missing prune directory a success; assert a cache-root `git-meta-*.txt` survives.

VERDICT: REVISE

### Architect's response

All 7 checked against the code; 6 taken in full, 1 in part.

1. Taken. Verified `claude-implement.sh:297-302` reports `ok` for BLOCKED/MISSING. Under `CW_OUT_DIR` a launcher now deletes nothing; `run-goal.sh` (succeed vs wake) owns the folder. Standalone deletion on `ok` stays.
2. Taken. A subshell umask does not reach the parent's redirect; a parent umask is inherited by the implementer. Output files are now pre-created 0600 and redirected onto; the launcher umask never changes.
3. Taken. Verified the cache root is 0755 (`git-guard.sh:46-48`, `stat`). A helper creates the cache root, `runs/` and `grok/` and sets each 0700 before any `mktemp`.
4. Taken. Verified the retry and fallback paths reassign `RAW` (`claude-implement.sh:488-509`). Every raw/`.err` pair is tracked in a list; deletion runs after `usage_lines`.
5. Taken. My recon grep missed `trap cleanup EXIT` in `proof-test.sh` and `signal-test.sh`; those traps stay. `HOME` and `TMPDIR` are exported script-wide (`grok-review-test.sh` set `HOME` on one call only). The suite guard also uses a private `HOME` and fails if the real cache listing changes.
6. Taken in part. The retry leak in `codex_once` (prompt + jsonl per attempt) is fixed. Rejected: moving the Codex report and return handoff into `RUN_DIR`. Codex writes the return handoff inside its `workspace-write` sandbox, which allows `$TMPDIR` but not `~/.cache`, so the move needs a new writable root on the legacy launcher. Recorded in Key decisions: a Codex wake read after ~3 idle days may still lose its report. Assumption 8 is now scoped to the Claude launcher.
7. Taken. The prune is rooted at `runs/` and `grok/` only, a missing directory is success, `|| true` under `set -e`, and a test asserts a `git-meta-*.txt` survives. The one-off clear deletes only house prefixes older than one day, after `pgrep -f` on the house `scripts/` path excluding its own line.

## Round 2 — Grok

I'll re-read the revised plan and check it against the earlier findings and the code those findings cited.The six taken findings are closed. The Codex exception is a real sandbox limit, and the new cleanup sentence breaks the caller that still has to read those files.

Prior findings: `CW_OUT_DIR` no longer deletes on `ok`, so a later wake still has `LOG:` and `stderr:`. Output files are pre-created `0600` without changing the launcher umask. The cache root, `runs/`, and `grok/` are created and set to `0700`. Every retry raw is tracked, and deletion waits until after `usage_lines`. Tests export `HOME` and `TMPDIR` for the whole script, keep the existing `cleanup` traps, and the suite guard watches the real cache. Prune treats a missing directory as success, stays inside `runs/` and `grok/`, and the one-off delete is older-than-a-day and matched on `claude-coding-workflow/scripts/`. Leaving the Codex report and return handoff in `$TMPDIR` is consistent with `deepseek-code.sh`: Codex writes both itself, and `workspace-write` only has the workspace, `$TMPDIR`, and the gitdirs.

1. **`codex_once` deleting the jsonl after every attempt removes files the caller still uses.** The main loop and the smoke loop call `tail -n 40 "${LAST_JSONL}.err"` only after `codex_once` returns (`deepseek-code.sh` 388 and 508), then `emit_and_exit` prints `LOG:` and `stderr:` (352–354). A rate-limited run retries up to three times (486–506). Deleting the jsonl and `.err` inside `codex_once` drops the error text and leaves the stop file pointing at paths that are already gone. The prompt file is the one the caller never reads again, except the dry-run path, which prints `PROMPT_FILE:` and exits first (309–317).
   Fix: delete the prompt file after the exec returns, and delete the jsonl and `.err` only for an attempt the loop is about to retry; keep the last pair.

2. **`OUT` is not an existing override.** `grok-review.sh` (229, 269) and `claude-goal-review.sh` (231, 250) assign `OUT` from `GROK_REVIEW_OUT` and `CLAUDE_REVIEW_OUT`. An incoming `OUT` is overwritten. The header comment that mentions `OUT` is stale. Honoring it would send verdicts to whatever ambient `OUT` a shell or Make already exported, outside the `0700` tree.
   Fix: keep only `GROK_REVIEW_OUT` and `CLAUDE_REVIEW_OUT` as path overrides.

3. **The mode test never starts from the cache root this machine already has.** `git_meta_init` creates `~/.cache/claude-coding-workflow` at `0755` and does not change an existing directory (`git-guard.sh` 46–48). Item 8 checks `0700` only on a fresh `HOME`, which passes if the helper chmods directories it just created and leaves an existing root alone. Filenames under `grok/` (session id and timestamp) stay listable.
   Fix: seed a `0755` cache root, run the helper, and assert that root, `runs/`, and `grok/` are `0700`.

VERDICT: REVISE

### Architect's response

All 3 taken.

1. Taken. Verified: the rate-limit loop and the error branch tail `${LAST_JSONL}.err` after `codex_once` returns (`deepseek-code.sh:388`, `:508`). The prompt file goes once its exec returns; a jsonl/`.err` pair goes only for an attempt about to be retried; the last pair is kept.
2. Taken. `OUT` is assigned, not read, in both review launchers; only `GROK_REVIEW_OUT` / `CLAUDE_REVIEW_OUT` are overrides, and the stale header is corrected.
3. Taken. The mode test also seeds an existing 0755 cache root, `runs/` and `grok/` and asserts the helper tightens them.

## Round 3 — Grok

I'll re-read the revised plan and check the three remaining findings against the scripts they cite.The three last findings look covered in the text. I’ll check the scripts for anything the new wording still gets wrong.The three open findings are closed, and the revised text matches the call sites it cites.

The Codex cleanup now follows the loop. The prompt file is removed only after `codex exec` returns, and the dry-run path still prints `PROMPT_FILE:` and exits first (`deepseek-code.sh` 309–317). The jsonl and its `.err` are removed only when the rate-limit loop is about to retry. The last pair stays, so `tail` at lines 388 and 508 and `LOG:` / `stderr:` at 352–354 still see real files.

`OUT` is no longer treated as an override. Only `GROK_REVIEW_OUT` and `CLAUDE_REVIEW_OUT` win, which is what `grok-review.sh` (229, 269) and `claude-goal-review.sh` (231, 250) actually read, and the stale header comment is corrected.

The mode check now starts from the production layout. `runs/`, `grok/`, and the cache root must end up `0700` both on a fresh `HOME` and when they already exist at `0755`, which is what `git_meta_init` leaves behind (`git-guard.sh` 46–48).

The earlier rules still hold: under `CW_OUT_DIR` the launcher deletes nothing, files are pre-created `0600` without changing the launcher umask, and the Codex report and return handoff stay in `$TMPDIR` because that sandbox cannot write `~/.cache`.

VERDICT: APPROVED

### Resolution

APPROVED in round 3 (10 findings over 2 REVISE rounds: 9 taken, 1 in part). Awaiting user sign-off.
