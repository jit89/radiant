# shellcheck shell=bash
# Host git the implementer cannot hijack.
#
# deepseek-code.sh makes .git writable inside the Codex sandbox so the
# implementer can checkpoint-commit. Hooks and config in there name programs
# git runs — as the host user, outside the sandbox, invisible to the review
# diff, and still armed on the human's next `git status`. So:
#   1. every host git call runs with hooks, fsmonitor and signing off;
#   2. .git config / hooks / info are fingerprinted without running git and
#      re-checked after each implementer pass, before any git command;
#   3. once a change is seen, host git refuses to run at all — filter and
#      textconv drivers named in config cannot be switched off by flag.
#
# Callers: git_meta_init once (inside the repo), then git_meta_verify.

GIT_META_TAINTED=0
GIT_META_DIRS=()

git() {
  if [[ "${GIT_META_TAINTED:-0}" -eq 1 ]]; then
    echo "git $1: skipped — .git metadata changed; inspect it first" >&2
    return 1
  fi
  command git -c core.hooksPath=/dev/null -c core.fsmonitor=false \
    -c commit.gpgSign=false -c tag.gpgSign=false "$@"
}

# Per-worktree gitdir plus the common gitdir when they differ.
git_meta_init() {
  local d c
  d="$(git rev-parse --absolute-git-dir 2>/dev/null)" || return 1
  c="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || c="$d"
  GIT_META_DIRS=("$d")
  [[ "$c" == "$d" ]] || GIT_META_DIRS+=("$c")
}

# Write a sorted manifest (path, type, mode, content hash or link target) of
# everything in the gitdirs that can make git execute or hide something.
git_meta_manifest() {
  python3 - "$1" "${GIT_META_DIRS[@]}" <<'PY'
import hashlib, os, stat, sys

out, dirs = sys.argv[1], sys.argv[2:]
NAMES = ("config", "config.worktree", "hooks", "info")
# Written by git itself: repack (run by background auto-maintenance after
# commits) regenerates info/refs, a ref list for dumb HTTP that nothing runs.
GENERATED = ("info/refs",)
rows = []

def add(path, rel):
    if rel in GENERATED:
        return
    st = os.lstat(path)
    if stat.S_ISLNK(st.st_mode):
        rows.append(f"{path}\tlink\t-\t{os.readlink(path)}")
    elif stat.S_ISDIR(st.st_mode):
        rows.append(f"{path}\tdir\t{oct(st.st_mode & 0o7777)}\t-")
        for name in sorted(os.listdir(path)):
            add(os.path.join(path, name), f"{rel}/{name}")
    else:
        with open(path, "rb") as f:
            digest = hashlib.sha256(f.read()).hexdigest()
        rows.append(f"{path}\tfile\t{oct(st.st_mode & 0o7777)}\t{digest}")

for d in dirs:
    for name in NAMES:
        p = os.path.join(d, name)
        if os.path.lexists(p):
            add(p, name)

with open(out, "w") as f:
    f.write("".join(r + "\n" for r in sorted(rows)))
PY
}

# Print each path whose manifest row was added, removed, or changed.
git_meta_changed() {
  python3 - "$1" "$2" <<'PY'
import sys

def rows(p):
    with open(p) as f:
        return {line.split("\t", 1)[0]: line for line in f if line.strip()}

a, b = rows(sys.argv[1]), rows(sys.argv[2])
for path in sorted(set(a) | set(b)):
    if a.get(path) != b.get(path):
        print(path)
PY
}

# Compare the gitdirs to the saved manifest; save one if there is none.
# On a change: taint host git, set GIT_META_CHANGED, return 1. Call it
# directly, never in $(...) — the taint must land in the caller's shell.
GIT_META_CHANGED=""
git_meta_verify() {
  local saved="$1" now="$2"
  git_meta_manifest "$now"
  if [[ ! -f "$saved" ]]; then
    cp "$now" "$saved"
    return 0
  fi
  GIT_META_CHANGED="$(git_meta_changed "$saved" "$now" | tr '\n' ' ')"
  [[ -n "$GIT_META_CHANGED" ]] || return 0
  GIT_META_TAINTED=1
  return 1
}
