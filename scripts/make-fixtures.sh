#!/usr/bin/env bash
# Builds Histq's git fixture repos, deterministic and isolated from the user's git config.
#
# Usage: scripts/make-fixtures.sh <dir> [--big N] [--portable]
#
#   <dir>/graph            branches, merges, tags, stashes, remote, worktree, WIP (HEAD = main)
#   <dir>/graph-origin.git bare remote of graph (graph's origin = ../graph-origin.git)
#   <dir>/graph-wt         linked worktree of graph on branch wt (not built with --portable)
#   <dir>/conflict         main merging feature, stopped with 3 conflicted files
#   <dir>/conflict-rebase  feature rebasing onto main, stopped with the same 3 conflicts
#   <dir>/expected/        expected results (long-A1-B2-AB3.txt)
#   <dir>/big              --big N: N commits (linear plus merges) via git fast-import
#
# --portable skips graph-wt so extensions.relativeWorktrees is never set (git < 2.48 refuses it).
#
# Safety: refuses an empty argument, /, $HOME, and any existing non-empty folder without the
# marker file .histq-fixtures. It deletes only the subfolders listed above (and .home).
set -euo pipefail

die() { echo "make-fixtures: $*" >&2; exit 1; }
usage() { echo "usage: make-fixtures.sh <dir> [--big N] [--portable]" >&2; exit 2; }

dir="" npos=0 big="" portable=0
while [ $# -gt 0 ]; do
  case "$1" in
    --big) [ $# -ge 2 ] || usage; big="$2"; shift 2 ;;
    --portable) portable=1; shift ;;
    -h|--help) usage ;;
    -?*) usage ;;
    *) dir="$1"; npos=$((npos + 1)); shift ;;
  esac
done
[ "$npos" -eq 1 ] || usage
[ -n "$dir" ] || die "refusing an empty folder argument"
if [ -n "$big" ]; then
  case "$big" in *[!0-9]*) die "--big needs a positive number" ;; esac
  [ "$big" -gt 0 ] || die "--big needs a positive number"
fi

# ---- Safety guard (runs before anything is written) ----
MARKER=".histq-fixtures"
real_home=""
if [ -n "${HOME:-}" ] && [ -d "$HOME" ]; then real_home="$(cd "$HOME" && pwd -P)"; fi

if [ -e "$dir" ] || [ -L "$dir" ]; then
  [ -d "$dir" ] || die "not a folder: $dir"
  root="$(cd "$dir" && pwd -P)"
  [ "$root" != "/" ] || die "refusing /"
  [ -z "$real_home" ] || [ "$root" != "$real_home" ] || die "refusing \$HOME"
  if [ -n "$(ls -A "$root")" ] && { [ ! -f "$root/$MARKER" ] || [ -L "$root/$MARKER" ]; }; then
    die "refusing non-empty folder without $MARKER: $root"
  fi
else
  mkdir -p "$dir"
  root="$(cd "$dir" && pwd -P)"
  [ "$root" != "/" ] || die "refusing /"
  [ -z "$real_home" ] || [ "$root" != "$real_home" ] || die "refusing \$HOME"
fi
: > "$root/$MARKER"

rm -rf "${root:?}/graph" "${root:?}/graph-origin.git" "${root:?}/graph-wt" \
  "${root:?}/conflict" "${root:?}/conflict-rebase" "${root:?}/expected" "${root:?}/.home"
if [ -n "$big" ]; then rm -rf "${root:?}/big"; fi

# ---- Isolation ----
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES \
  GIT_COMMON_DIR GIT_NAMESPACE GIT_CEILING_DIRECTORIES GIT_CONFIG GIT_CONFIG_PARAMETERS \
  GIT_TEMPLATE_DIR GIT_SEQUENCE_EDITOR XDG_CONFIG_HOME
mkdir -p "$root/.home"
export HOME="$root/.home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_EDITOR=true GIT_TERMINAL_PROMPT=0 TZ=UTC LC_ALL=C
export GIT_AUTHOR_NAME="Histq Fixture" GIT_AUTHOR_EMAIL="fixture@histq.invalid"
export GIT_COMMITTER_NAME="Histq Fixture" GIT_COMMITTER_EMAIL="fixture@histq.invalid"
export GIT_CONFIG_COUNT=6 \
  GIT_CONFIG_KEY_0=init.defaultBranch GIT_CONFIG_VALUE_0=main \
  GIT_CONFIG_KEY_1=commit.gpgSign GIT_CONFIG_VALUE_1=false \
  GIT_CONFIG_KEY_2=tag.gpgSign GIT_CONFIG_VALUE_2=false \
  GIT_CONFIG_KEY_3=core.autocrlf GIT_CONFIG_VALUE_3=false \
  GIT_CONFIG_KEY_4=gc.auto GIT_CONFIG_VALUE_4=0 \
  GIT_CONFIG_KEY_5=advice.detachedHead GIT_CONFIG_VALUE_5=false

# Fixed, increasing dates: one hour per commit from 2026-01-01 00:00 UTC.
T0=1767225600
n=0
tick() {
  n=$((n + 1))
  export GIT_AUTHOR_DATE="$((T0 + n * 3600)) +0000" GIT_COMMITTER_DATE="$((T0 + n * 3600)) +0000"
}
commit() { tick; git commit -q -m "$1"; }

# The repo's own identity (task 2.3 checks a profile wins over it) and signing off.
local_config() {
  git config user.name "Fixture Local"
  git config user.email "local@histq.invalid"
  git config commit.gpgSign false
  git config tag.gpgSign false
}

app_swift() { # $1 = count value, $2 = 1 to add the unstaged block
  cat <<'EOF'
import Foundation

/* Histq fixture source.
   A block comment over
   several lines. */
struct Greeter {
    let name: String
EOF
  printf '    var count: Int = %s\n' "$1"
  cat <<'EOF'

    func greet() -> String {
        return "Hello, \(name)!"
    }
}

// MARK: - Helpers

func scaled(_ value: Double) -> Double {
    value * 2.5
}

let limits = [1, 2, 3, 0x1F]

enum Mode: String {
    case fast = "fast"
    case slow = "slow"
}

func main() {
    let greeter = Greeter(name: "Histq")
    print(greeter.greet())
EOF
  if [ "$2" = 1 ]; then
    cat <<'EOF'
    let ratio = 3.14
    let label = "ratio"
    print(label, ratio)
    print("done", 0b1010)
EOF
  fi
  cat <<'EOF'
    if greeter.count > 10 {
        print("count: \(greeter.count)")
    }
}
EOF
}

readme() { # $1 = 1 for the WIP version (2 lines replaced)
  printf '# Graph fixture\n\nThis repo exercises the Histq commit graph.\n'
  if [ "$1" = 1 ]; then
    printf 'It has merges, tags, stashes and a remote (edited).\nIt also has a worktree (edited).\n'
  else
    printf 'It has merges, tags, stashes and a remote.\nIt also has a worktree.\n'
  fi
  printf '\nEnd of file.\n'
}

make_graph() (
  n=0
  git init -q "$root/graph"
  cd "$root/graph"
  local_config

  mkdir -p src docs
  readme 0 > README.md
  app_swift 42 0 > src/app.swift
  printf 'alpha\nbeta\ngamma\ndelta\nepsilon\n' > old-name.txt
  printf 'first line\nsecond line\nlast line without newline' > no-newline.txt
  printf '\211PNG\r\n\032\n\000\001\002\003\004\005\006\007' > image.bin
  git add -A
  commit "Initial commit"

  printf '# Guide\n\nHow to use the fixture.\n' > docs/guide.md
  git add docs/guide.md
  commit "Add guide"
  git tag v0.1

  git switch -q -c develop
  printf 'struct Config {\n    var debug = false\n}\n' > src/config.swift
  git add src/config.swift
  commit "Add config"
  printf 'struct Config {\n    var debug = false\n    var verbose = true\n}\n' > src/config.swift
  git add src/config.swift
  commit "Add verbose flag"

  git switch -q -c feature
  printf 'func feature() {}\n' > src/feature.swift
  git add src/feature.swift
  commit "Start feature"
  printf 'func feature() {\n    print("feature")\n}\n' > src/feature.swift
  git add src/feature.swift
  commit "Finish feature"

  git switch -q develop
  tick
  git merge -q --no-ff -m "Merge branch 'feature' into develop" feature
  printf '# Changelog\n\n- feature\n' > CHANGELOG.md
  git add CHANGELOG.md
  commit "Add changelog"

  git switch -q main
  printf '# Guide\n\nHow to use the fixture.\n\nSee README.md.\n' > docs/guide.md
  git add docs/guide.md
  commit "Link README from guide"

  # stash@{1}: plain stash based on this main commit.
  printf '# Guide\n\nHow to use the fixture (stashed edit).\n\nSee README.md.\n' > docs/guide.md
  tick
  git stash push -q -m "guide tweaks"

  tick
  git merge -q --no-ff -m "Merge branch 'develop'" develop
  tick
  git tag -a v1.0 -m "Release 1.0"

  git switch -q -c series
  for i in 1 2 3 4 5; do
    printf 'step %s\n' "$i" > "docs/step-$i.md"
    git add "docs/step-$i.md"
    commit "Series step $i"
  done

  git switch -q main
  printf '1.0.1\n' > VERSION
  git add VERSION
  commit "Bump version"

  # origin: main in sync, develop ahead by 1, feature behind by 1.
  git init -q --bare "$root/graph-origin.git"
  git remote add origin ../graph-origin.git
  git push -q -u origin main develop feature
  git switch -q feature
  printf 'func feature() {\n    print("feature v2")\n}\n' > src/feature.swift
  git add src/feature.swift
  commit "Polish feature (pushed)"
  git push -q origin feature
  git reset -q --hard HEAD~1
  git switch -q develop
  printf '# Changelog\n\n- feature\n- verbose flag\n' > CHANGELOG.md
  git add CHANGELOG.md
  commit "Update changelog (not pushed)"
  git switch -q main

  if [ "$portable" -eq 0 ]; then
    git worktree add -q --relative-paths -b wt ../graph-wt develop
    printf '# Changelog\n\n- feature\n- verbose flag\n- worktree edit\n' > "$root/graph-wt/CHANGELOG.md"
  fi

  # stash@{0}: with -u (has a third parent holding scratch.txt), based on main's tip.
  printf '1.0.2\n' > VERSION
  printf 'scratch\n' > scratch.txt
  tick
  git stash push -q -u -m "scratch with untracked"

  # WIP on main.
  app_swift 7 0 > src/app.swift
  git add src/app.swift                       # staged hunk: count 42 -> 7
  app_swift 7 1 > src/app.swift               # unstaged hunk: 4 added lines
  printf 'staged new file\n' > staged.txt
  git add staged.txt                          # staged add
  git mv old-name.txt new-name.txt            # staged rename
  readme 1 > README.md                        # unstaged: 2 lines replaced (4 changed lines)
  printf 'first line\nsecond line edited\nlast line still without newline' > no-newline.txt
  printf '\211PNG\r\n\032\n\000\011\012\013\014\015\016\017' > image.bin   # unstaged binary
  printf 'untracked\n' > untracked.txt
  printf 'a file named -rf\n' > ./-rf          # untracked, name starts with a dash
)

long_txt() { # $1 = base | main | feature
  local i line
  for ((i = 1; i <= 100; i++)); do
    line="line $i: nội dung gốc"
    case "$1:$i" in
      main:10 | main:40 | main:55 | main:70) line="line $i: nội dung main" ;;
      feature:10 | feature:20 | feature:40 | feature:70) line="line $i: nội dung feature" ;;
    esac
    printf '%s\n' "$line"
  done
}

conflict_base() ( # $1 = repo folder; same commits (same hashes) every call
  n=100
  git init -q "$1"
  cd "$1"
  local_config
  long_txt base > long.txt
  printf 'This file is deleted on feature\nand modified on main.\n' > gone.txt
  git add -A
  commit "Base"

  git switch -q -c feature
  long_txt feature > long.txt
  git rm -q gone.txt
  printf 'add.txt from feature\n' > add.txt
  git add -A
  commit "Feature changes"

  git switch -q main
  long_txt main > long.txt
  printf 'This file is deleted on feature\nand modified on main (edited).\n' > gone.txt
  printf 'add.txt from main\n' > add.txt
  git add -A
  commit "Main changes"
)

unmerged_count() { git -C "$1" diff --name-only --diff-filter=U | wc -l | tr -d ' '; }

make_conflict() (
  conflict_base "$root/conflict"
  cd "$root/conflict"
  git merge --no-edit feature > /dev/null 2>&1 || true
  [ -f .git/MERGE_HEAD ] || die "conflict: merge did not stop"
  [ "$(unmerged_count .)" = 3 ] || die "conflict: expected 3 unmerged paths"
)

make_conflict_rebase() (
  conflict_base "$root/conflict-rebase"
  cd "$root/conflict-rebase"
  git switch -q feature
  git rebase main > /dev/null 2>&1 || true
  [ -d .git/rebase-merge ] || die "conflict-rebase: rebase did not stop"
  [ "$(unmerged_count .)" = 3 ] || die "conflict-rebase: expected 3 unmerged paths"
)

# A = main (ours, stage 2), B = feature (theirs, stage 3). Conflicts: #1 line 10, #2 line 40,
# #3 line 70. One-sided changes applied: line 20 (feature), line 55 (main).
make_expected() {
  mkdir -p "$root/expected"
  local i
  for ((i = 1; i <= 100; i++)); do
    case "$i" in
      10 | 55) printf 'line %s: nội dung main\n' "$i" ;;
      20 | 40) printf 'line %s: nội dung feature\n' "$i" ;;
      70) printf 'line %s: nội dung main\nline %s: nội dung feature\n' "$i" "$i" ;;
      *) printf 'line %s: nội dung gốc\n' "$i" ;;
    esac
  done > "$root/expected/long-A1-B2-AB3.txt"
}

# N commits: every 10 commits a side commit (refs/heads/topic) forks off main and is merged
# back 4 commits later; all others are linear commits on main.
make_big() (
  git init -q "$root/big"
  cd "$root/big"
  local_config
  awk -v total="$1" -v t0="$T0" 'BEGIN {
    head = 0; side = 0
    for (i = 1; i <= total; i++) {
      kind = "main"
      if (i % 10 == 5 && head && i + 4 <= total) kind = "side"
      else if (i % 10 == 9 && side) kind = "merge"
      print "commit refs/heads/" (kind == "side" ? "topic" : "main")
      print "mark :" i
      ts = t0 + i * 60
      print "author Big History <big@histq.invalid> " ts " +0000"
      print "committer Big History <big@histq.invalid> " ts " +0000"
      msg = (kind == "merge" ? "Merge topic " side : "Commit " i)
      print "data " length(msg); print msg
      if (head) print "from :" head
      if (kind == "merge") print "merge :" side
      content = "commit " i "\n"
      print "M 644 inline src/f" (i % 97) ".txt"
      print "data " length(content); printf "%s\n", content
      if (kind == "side") side = i
      else { head = i; if (kind == "merge") side = 0 }
    }
  }' | git fast-import --quiet
  git symbolic-ref HEAD refs/heads/main
  git reset -q --hard
)

make_graph
make_conflict
make_conflict_rebase
make_expected
if [ -n "$big" ]; then make_big "$big"; fi
echo "fixtures ready in $root"
