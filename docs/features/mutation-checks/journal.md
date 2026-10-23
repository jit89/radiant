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
