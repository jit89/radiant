# Plan: the proof sandbox allows setting file times (macOS 27)
_Locked via crucible — by Claude + cobalt, 2026-11-03._

## Goal

On macOS 27.0.1 the proof sandbox refuses to set a file's times anywhere,
including the trees a proof or a `worktree_setup` may write.
`scripts/lib/proof-sandbox.py` allows writes as a list of named operations,
and setting times is now checked under an operation none of them names;
only the `file-write*` wildcard matches it.

Every proof or setup that sets times fails. Measured:
- `cargo fetch` unpacking a crate;
- `tar -x`;
- `cp -p`;
- Python's `shutil.copy2`.

The Rust tier-rules item stopped on it at its step 2b
(`docs/features/rust-tier-rules/journal.md`).

This item makes setting times work where writes are allowed, keeps it refused
everywhere writes are refused, and makes the pre-proof self-test fail loudly
the next time macOS changes this.

## Approach

1. **Every write allow and every write deny names `file-write*` beside the
   named operations** (`WRITE` in `proof-sandbox.py`). The profile's order
   does not change: the allows for the root, tmp, deps (setup only) and the
   pnpm lock folder (setup only); then the denials for secrets, house state,
   the `run-goal-*` regex and the root's `.git`; then the metadata allows;
   then the temp folder's re-allow, last. Concretely:
   - `WRITE` becomes `"file-write* " + <the nine named operations>`, so
     every rule that uses it carries both forms;
   - the literal `/dev/null` and `/dev/zero` allow, already `file-write*`,
     is unchanged;
   - the `out` file's `file-write-data` allow stays as it is: the proof
     appends to it and never sets its times;
   - the `file-link` rules are unchanged; they are a separate operation.

   This works for these reasons, measured on macOS 27.0.1 (assumptions 3
   and 4):
   - a named rule still beats a wildcard rule whatever their order (row E),
     so each deny must keep naming the operations; a wildcard alone would
     lose to a named allow;
   - between two wildcard rules, the later one wins (rows B and C), so
     each deny must also carry the wildcard and come after the allows;
   - with both forms in both rules, deny after allow (row F), the tree
     accepts writes and time changes while `.git` refuses both.

   A wildcard allow with only a named deny (row A) would leave time changes
   open in `.git`. The plants (step 3) show each form is needed.

   **The wildcard also allows operations the nine names leave out**
   (Grok round 1). Probing found three more real write operations:
   `file-write-acl`, `file-write-finderinfo` and `file-write-mount`. Today
   they are refused everywhere; a `file-write*` allow would open them on the
   root, tmp, deps and the pnpm lock folder. So each of those trees also
   gets `(deny file-write-acl file-write-finderinfo file-write-mount
   (subpath …))`, emitted **last** among the write rules: after the `--tmp`
   re-allow (which carries `file-write*` and comes after the secret
   denials). That way no later wildcard allow reopens them (Grok round 2).
   A named deny beats the wildcard allow whatever the order (assumption 3),
   and the unnamed operation that sets times is not one of the three
   (assumption 1: allowing all three did not let `touch` through). The tests
   assert the ACL write still returns EPERM in the root, and `touch` still
   works (step 3).
   Any other operation the wildcard opens is unknown; the risk is stated.

2. **The self-test gets two checks** (`proof_sandbox_selftest` in
   `scripts/lib/proof-sandbox.sh`, Q1):
   - setting a pre-created file's time inside the root succeeds (Python
     `os.utime` to a new stamp, read back); failure reason "setting a file's
     time in the root is refused";
   - the same call on a pre-created file in a `.git` folder inside the
     self-test's root fails with EPERM and leaves the stamp unchanged;
     failure reason "setting a file's time in the root's .git was not
     refused".

   Both files are made, and given a fixed old stamp, before the profile
   runs. The self-test's
   generated profile is the real generator's output (it already calls
   `proof-sandbox.py`), so a regression in the generator fails it. The
   self-test's existing checks are unchanged.

3. **Tests** in `scripts/tests/proof-sandbox-test.sh`, using its existing
   helpers.

   **The time check.** Every case acts on a file created **before** the
   sandboxed command, then given a fixed old stamp (`os.utime(p, (1e9,
   1e9))`). The sandboxed command is Python `os.utime(p, (2e9, 2e9))`,
   through the file's existing `errno` helper:
   - **allowed:** it succeeds, and the stamp reads `2e9` afterwards;
   - **refused:** it fails with `EPERM`, and both stamps still read `1e9`.

   Any other error, or a missing file, fails the case. A `tar -x` of a
   one-file archive is an extra **allowed** case only (in a refused tree it
   would fail on `file-write-create`, which says nothing about times).

   **Allowed** in the root, in tmp, and in deps under `--setup`.

   **Refused** where writes are refused **beneath a write allow**: row A's
   hole only opens where an ancestor allow matches. Each case runs a profile
   whose `HOME` is inside the root (the self-test's shape), so these files
   are under `--root`, pre-created:
   - the root's `.git`;
   - a secret-list path (`HOME/.ssh/x`);
   - house state (`HOME/.cache/claude-coding-workflow/runs/x` and
     `logs/x`);
   - a `run-goal-*` folder under that cache;
   - deps without `--setup`.

   One more refused case sits outside every tree, as a control.

   **The extra operations:** an ACL write (`chmod +a "everyone deny read"
   f`) is refused with EPERM, both in the root and in `--tmp` (the tree
   whose re-allow comes last). Measured on 27.0.1 with a
   `file-write*` allow: without the named deny it succeeds, with it it is
   refused, and `touch` still works. `file-write-finderinfo` and
   `file-write-mount` are denied by name too, but have no unprivileged
   probe here: writing `com.apple.FinderInfo` with `xattr -w` is checked as
   `file-write-xattr`, and succeeds with or without the deny (today's
   profile allows it too, so it is no widening). Both are recorded
   unproved in the evidence.

   **Plants.** For each plant, the harness:
   - copies `scripts/` to a temporary tree (`plant-runs-on-copies`, the
     house memory note), with `GOALS.example.md` staged beside it: the test
     reads `$HERE/../GOALS.example.md` under `set -e` before the self-test
     section. The clean copy must run green to the end before any plant
     counts;
   - mutates `proof-sandbox.py` there;
   - runs that copy's `proof-sandbox-test.sh`, whose `GEN` and sourced
     `proof-sandbox.sh` resolve inside the copy (the test resolves both
     relative to its own location; the build checks this first and fixes
     it if it doesn't).

   The live `scripts/lib/` is never edited. The plants:
   - **P1:** `WRITE` without the wildcard (today's profile). The allowed
     cases go red, and the self-test's root check fails.
   - **P2:** the wildcard only in the allows, not in the denies. The
     in-root `.git`, secret, state and `run-goal-*` time cases go red
     (row A), and the self-test's `.git` check fails.
   - **P3:** the wildcard only in the denies, not in the allows. The allowed
     cases go red.
   - **P4:** the denies moved before the allows. The in-root refused cases
     go red (row G); the control outside every tree stays refused, as it has
     no allow above it.
   - **P5:** the denies carry `file-write*` alone, without the nine names
     (row E). The existing in-root **write** denials (create and append in
     `.git` and on the secret path) go red, while the time cases stay
     green; this shows why the names stay.
   - **P6:** the extra-operations deny removed. The ACL case goes red.

   Each plant must turn at least one case red. The clean generator must turn
   none red, and the existing cases must stay green. The self-test's `.git`
   check uses the same pre-created-file, `os.utime`, `EPERM` shape, so P2
   fails it for the right reason, not on a missing file.

4. **Evidence.** Append a dated section to
   `docs/features/proof-sandbox/EVIDENCE.md`, "Correction (2026-11-03, macOS
   27.0.1): setting file times", with:
   - the measurement matrix (rows A to G, `touch` and append, a tree and its
     `.git`);
   - the reach (`cargo fetch`, `tar -x`, `cp -p`, `shutil.copy2`);
   - the plant results from step 3.

   The precedence comment above `WRITE` in `proof-sandbox.py` is rewritten to
   say why both forms are named (assumptions 3 and 4). The proof-sandbox
   `PLAN.md` is not edited (it is the signed contract); the correction lives
   in EVIDENCE.md.

5. **The Rust item resumes.** Rerun its step 2b
   (`docs/features/rust-tier-rules/fixture/run-plants.sh 2b`) after this
   commit, recording the result in that item's journal, not this one.

6. **Follow-up recorded.** `docs/FUTURE-WORK.md` gets the Axum + SQLx rules
   item (the user's choice: after the core Rust rules), with the hazards
   already found:
   - SQLx's compile-time macros read `DATABASE_URL` from `.env` (which the
     host refuses) or need a committed `.sqlx/` with `SQLX_OFFLINE=true`;
   - `#[sqlx::test]` needs a database server and credentials (a password in
     `DATABASE_URL` is not stripped by name);
   - `sqlx::migrate!` embeds a migrations folder, a registration point;
   - Axum handler panics on runtime worker threads;
   - servers that hang need a timeout;
   - the load-bearing choice between SQLite in memory and a real Postgres.

7. **Review and release.** This changes a security gate, so it goes through:
   - a fresh read-only Opus review of the diff, then narrow re-review rounds
     until DONE, with a narrow round for any change after DONE;
   - the full suite after DONE;
   - one commit on the user's OK;
   - `install.sh`;
   - `scripts/make-release.sh`, then push `main` and
     `refs/heads/release:refs/heads/release` (no force).

## Key decisions & tradeoffs

- **Both forms in every write rule, not the wildcard alone.** A
  wildcard-only profile would depend on rule order alone. Named operations
  beat wildcards whatever their order (row E), so a later named allow
  anywhere would re-open a denied path. Keeping the named operations keeps
  the old guarantee on any macOS where only they matter. Adding the wildcard
  covers the operation macOS 27 checks without a name. Cost: the rules are
  longer.
- **No probe for the unnamed operation's real name.** It was not found by
  name probes or in the dyld cache. The wildcard covers it and any later
  split of the same kind. Cost: if the operation is ever given a public name
  that some other rule needs, this item does not know it.
- **The self-test checks behaviour, not the profile text (Q1, user).** It
  catches the next silent macOS change before the first proof of a walk.
  Cost: a self-test that is wrong on some machine stops every walk until
  fixed; `CW_PROOF_SANDBOX=off` remains the user's way out.
- **Evidence goes in the proof-sandbox EVIDENCE.md, not its PLAN.md.** The
  signed plan stays as it was; the correction is dated next to the earlier
  measurements it amends.

## Assumptions

1. Setting times is refused in every tree under the current profile, while
   create, write, chmod, rename and unlink work — measured 2026-11-02/03,
   macOS 27.0.1. Probes: `touch` in root, tmp and deps; every named write
   operation allowed (plus `file-write-acl`, `file-write-finderinfo`,
   `file-write-mount`, `file-revoke`) still refused; `(deny default)` with
   `(allow file-write-times)` refused.
2. Reach: `cargo fetch`, `tar -x`, `cp -p` and Python's `shutil.copy2` fail
   under the generated profile. No suite case sets times —
   `scripts/tests/proof-sandbox-test.sh`.
3. A named rule beats a wildcard rule whatever their order —
   `docs/features/proof-sandbox/EVIDENCE.md:223`. Still true on 27.0.1 for
   named operations (row E).
4. Rows measured on 27.0.1, each `(allow default) (deny file-write* <dir>)`
   followed by:

   | Row | Rules (T = a tree, .git inside it) | touch T | write T | touch .git | write .git |
   |---|---|---|---|---|---|
   | A | allow* T; deny named .git | ok | ok | **ok** | no |
   | B | allow* T; deny* .git | ok | ok | no | no |
   | C | deny* .git; allow* T | ok | ok | ok | ok |
   | D | allow* T; deny *+named .git | ok | ok | no | no |
   | E | allow named T; deny* .git | no | ok | no | ok |
   | F | allow *+named T; deny *+named .git | ok | ok | no | no |
   | G | deny *+named .git; allow *+named T | ok | ok | ok | ok |

5. `proof_sandbox_selftest` runs the real generator and checks writes,
   secrets, temp areas and network, with no check that sets times —
   `scripts/lib/proof-sandbox.sh:19-60`.
6. The implementer's sandbox is Claude Code's own and is out of this item —
   proof-sandbox PLAN step 6.
7. `scripts/lib/` ships on the release branch — `release/MANIFEST`
   (`scripts`).

## Risks / open questions

- **The wildcard may open an operation nobody has named.** The three known
  extra write operations (`file-write-acl`, `file-write-finderinfo`,
  `file-write-mount`) are denied by name on the allowed trees. Only the ACL
  deny has a probe (root and tmp); the other two are unproved.
  An operation unknown to the probes, besides the one that sets times,
  would be allowed on the trees a proof may already write; it stays refused
  everywhere else, because every deny carries the wildcard.
- **Another operation may have moved the same way.** Only setting times was
  found refused; create, write, chmod, rename and unlink were checked. The
  wildcard covers any other such move on the allowed trees.
- **Older macOS.** The change only adds a wildcard beside the named
  operations, so the rules behave the same as before on a version where
  only the named operations matter (row F's shape). This is untested on an
  older version: none is available here.
- **The Rust item's step 2b may hit a second denial** once times work (for
  example under `CARGO_HOME` in a proof). That is the Rust item's to
  record, and it stops that item again if it does.

## Out of scope

- Claude Code's implementer sandbox.
- Hard-link rules, network rules, the denial listing.
- The Rust tier rules themselves, beyond rerunning step 2b.
- The Axum + SQLx rules (recorded only).

## Amendment 1 (build, 2026-11-03): a fourth extra operation

The Opus round-1 review asked whether `file-write-unmount` exists on 27.0.1.
Probed: a profile naming it compiles and runs, while a bogus name
(`file-write-nonsense`) fails with "unbound variable" (exit 65). So it is a real
operation that a `file-write*` allow would open. It joins
`file-write-acl`, `file-write-finderinfo` and `file-write-mount` in the named
deny on the allowed trees, last among the write rules. Like finderinfo and mount
it has no unprivileged probe, so it is recorded as unproved. This only tightens
the profile.
