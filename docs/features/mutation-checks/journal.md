# Journal: mutation-checks (house item 8)

## 2026-10-23T20:31:43Z — ARCHITECT start
Crucible for FUTURE-WORK item 8 on the user's order (after item 17). Recon: the DONE route in run-goal.sh, proof_exec under the proof sandbox, the reviewer's verdict and FIX parsing. Decisions (user): Q1 the goal reviewer writes the mutations on a DONE verdict; Q2 a survivor is recorded (journal, warning event, walk-end line, the diff kept), not a stop, CW_MUTATION_GAPS=stop for a strict walk; Q3 on by default, 3 per goal, CW_MUTATIONS=0 off, at most 5. Cosmetic batch accepted. From recon: each mutation runs on a copy-on-write clone of the checkout after a green baseline in a clone (a plain export lacks a proof's untracked dependencies), in a temp folder (the sandbox refuses a root under the run folders). PLAN.md locked; Grok round 1 next.

## 2026-10-23T20:44:24Z — ARCHITECT round 1
Grok round 1: REVISE, 6 findings (git apply reaches the live gitdir in --jobs, proof_exec does not cd and lacks deps/network/caches, diff lines can turn the verdict MISSING and the resume prompt asks for none, no path grammar for untrusted diffs, scoring not by the host rule and no mutations event, the stop mode leaves the goal in progress); all taken. Strict mode now stops the walk after the goal lands (told the user). Round 2 resumes session 27b70da3.

## 2026-10-23T20:51:30Z — ARCHITECT round 2
Grok round 2: REVISE, 4 findings (the grammar rejected git diff's header, a clone without .git still reached the live index and parent repos, cutting on fences, strict mode looping and the scoring order); all taken. Round 3 resumes session 27b70da3.

## 2026-10-23T20:56:18Z — ARCHITECT round 3
Grok round 3: REVISE, 3 findings (git init on a copied gitfile or repo, executables are 100755, a stale test line and a block after the verdict); all taken. Round 4 resumes session 27b70da3.

## 2026-10-23T21:01:59Z — ARCHITECT round 4
Grok round 4: REVISE, 2 findings (the baseline commit needs a message and the wrapper's gpgSign/fsmonitor off; the cut must find the verdict line as verdict.py does); both taken. Round 5 (the last) resumes session 27b70da3.

## 2026-10-23T21:02:28Z — ARCHITECT round 4 correction
The round-4 plan edit had failed (an anchor), so the first round-5 launch saw the unchanged plan; it was stopped before reporting. The edits are now in PLAN.md (checked); round 5 relaunched.

## 2026-10-23T21:07:44Z — ARCHITECT round 5
Grok round 5 (MAX_ROUNDS): REVISE, 1 finding (a diff context line in a trailing block could be taken for the verdict); taken into PLAN.md (checked). No APPROVED within five rounds; the last change unreviewed by Grok. To the user: sign off as is, or one more Grok round.

## 2026-10-23T21:08:12Z — ARCHITECT round 6
The user chose one more Grok round, past MAX_ROUNDS, only to check the round-5 fix. Resumes session 27b70da3.

## 2026-10-23T21:17:53Z — ARCHITECT round 6
Grok round 6: REVISE, the cutter again (a list-marker verdict line and a verdict-shaped line in a trailing block). The user chose a redesign: the mutations come from a separate resumed reviewer turn after DONE; the verdict reply is untouched. PLAN.md revised (checked). Round 7 resumes session 27b70da3 to check the changed plan.

## 2026-10-23T21:26:00Z — ARCHITECT round 7
Grok round 7 (the redesign): REVISE, 2 findings in the new turn's plumbing (MUTATIONS_FILE inline and tabs lost; the fence vs the grammar); both taken (checked after a first edit failed on an anchor and logged nothing). Round 8 resumes session 27b70da3.

## 2026-10-23T21:32:18Z — ARCHITECT round 8
Grok round 8: APPROVED. PLAN.md to the user for sign-off.

## 2026-10-23T21:34:30Z — ARCHITECT sign-off
The user signed off PLAN.md (Grok APPROVED round 8). Build next, in-session: tests first, plants on copies, Opus review, a commit on the user's OK.

## 2026-10-23T22:05:05Z — ARCHITECT build
Built in-session: claude-goal-review.sh --mutations N (a resumed turn, the raw reply to its own file), lib/mutations.py (the grammar), run-goal.sh (CW_MUTATIONS checked at start; run_mutations in the DONE route: clones with a private git dir, a baseline, apply --recount --unidiff-zero after an lstat, the host rule, the record and event, diffs kept), run-goals.sh and wave-walk.sh (the walk-end survivors line, CW_MUTATION_GAPS=stop counting this invocation only), events.py (mutations). The 23 tests that drive run-goal or the walkers set CW_MUTATIONS=0; mutation-test.sh turns it on. Deviations from the plan: apply takes --recount and --unidiff-zero (a model's one-line mutation has no context, its hunk counts are often off); a block whose diff is outside a fence is skipped (no closed fence). Plants, each red (all in mutation-test.sh): no mutation run, contract paths accepted, symlink mode accepted, a fence inside a hunk ends the block, a timeout counted as caught, Ran 0 tests counted as green, no baseline, the clone keeps the copied .git, signing not turned off, strict counts every record, the launcher's text path (tabs lost), CW_MUTATIONS not checked, apply needs context, no walk-end summary in --jobs, no mutations event. Opus review next.

## 2026-10-23T22:35:59Z — ARCHITECT review round 1
Opus (fresh, read-only): FIX. Taken: (security) a nested repository in the checkout: the clone's git add -A would make it a submodule and git status would run a child git there, unsandboxed, reading the implementer's config; a clone with a .git below the top is now refused, and one with a submodule entry after add too (planted with both guards removed, the implementer's clean filter ran on the host; each guard alone keeps it from running). Deviations now recorded: the host rule is copied into mut_run, not factored with the host's own proof checks (factoring would change the host proof path); apply takes --recount --unidiff-zero. Notes taken: paths with whitespace rejected; a baseline clone that cannot be made has its own reason; a reply with no blocks or a parser failure is noted; the baseline runs only when a block was accepted; | kept out of reasons; MUT_DIR removed by on_exit; a temp folder inside the checkout is a skip; PHASE restored; the mutations turn names a fallback model (event payload); strict mode also checked after the start-of-walk integrations. Tests added: a nested repository (its filter never runs), a symlink destination, a tab-indented file end to end, a quoted rule, a failed turn, an oversized reply, BLOCKED, the serial .git untouched, --jobs strict. A symlink destination is refused twice (the lstat check and git apply itself): the plant removing the lstat check stays green. Not tested: a cache carried by the proof temp copy, a clone that cannot be made, a timeout that leaves the tree dirty, a member's own index after --jobs (removed after integration).

## 2026-10-24T06:30:39Z — ARCHITECT review round 2
Opus (narrow, read-only): FIX. Taken: (security) on a case-insensitive disk a nested repository named .GIT passed the name check, and the submodule check after add failed open: ls-files piped to grep -q died of SIGPIPE under pipefail, so the clone was accepted because a submodule entry was found. Now the name is matched in any case (find -iname) and the index listing is captured and searched, refusing the clone when it cannot be listed. Round 1's "each guard alone keeps it from running" held only for a lowercase .git; with these fixes it holds for both. Note taken: the clone's git reads no user or system config (GIT_CONFIG_GLOBAL=/dev/null, GIT_CONFIG_NOSYSTEM=1), so a filter or signer defined there never runs on implementer files. Tests added: a nested repository spelled .GIT with 400 tracked files after it; grammar cases for a path with a space or a tab. Plants, red: case-sensitive find with the piped check (the .GIT test), no find with the piped check, case-sensitive find with no submodule check, and round 1's nested and copied-.git plants re-anchored. Green by layering, as expected: the case-sensitive find alone (the submodule check catches it) and signing turned back on (no config is read). Notes left: an ignored nested repository also refuses the clone, so such a project skips every mutation, with the reason recorded (the safe side); round 1's "serial .git untouched" overstates the test, which checks .git/config only (the host's own git status refreshes the index anyway).

## 2026-10-24T06:42:06Z — ARCHITECT review round 3
Opus (narrow, read-only): DONE; the round-2 FIXes closed, the captured-listing match correct (ls-files -s C-quotes a path holding a newline, so no path fakes a line), dropping user and system config breaks nothing the clone needs. Notes taken after the verdict: a baseline that does not pass in a copy now records its outcome (the baseline in a copy: red|timeout|notests|moved|sandbox, with the reason when there is one), not always "baseline red", since the clone reads no core.excludesFile and a proof file ignored only there makes the baseline "moved"; the .GIT test carries ~100 KB of index after the gitlink (1600 files) so the old piped check is red every run, not usually. Plants, red: the old fixed reason text; the case-sensitive find with the piped check (1600 files). Round 2's entry should also have said: the clone loses the user's core.excludesFile (fail-safe: every mutation skipped, the reason now says why).

## 2026-10-24T06:57:22Z — ARCHITECT review round 4
Opus (narrow, read-only): DONE on the two notes taken after round 3 (MUT_WHY is cleared by mut_run and mut_clone, so no stale reason leaks; | stripped; 1600 files clear the 64 KB pipe) and the round-3 entry.
