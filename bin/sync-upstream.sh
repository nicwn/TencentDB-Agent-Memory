#!/usr/bin/env bash
#
# sync-upstream.sh — merge TencentCloud upstream into this fork WITHOUT losing
# the pi adaptation.
#
# WHY THIS EXISTS
# ---------------
# GitHub's web "Sync fork" button only performs a fast-forward. Once this fork
# has commits upstream does not have (the entire pi-extension/ layer), the
# button cannot fast-forward and offers only "Discard commits" — which deletes
# the pi adaptation. That has already happened once; see commit 7ae263b
# ("fix(pi): restore full pi adaptation lost in upstream sync").
#
# NEVER use the GitHub Sync fork button on this repository. Use this script.
#
# WHAT IT DOES
#   1. Refuses to run on a dirty working tree or outside the default branch.
#   2. Fetches upstream and shows exactly what is incoming.
#   3. Merges upstream/main (a merge, never a rebase — our commits are already
#      pushed, so rewriting them is the very failure mode we are avoiding).
#   4. Runs the test suite and the build as a gate.
#   5. If the merge conflicts, or either gate fails, it ABORTS and restores the
#      pre-merge state. A broken upstream change can never land silently in the
#      extension pi loads at startup.
#
# USAGE
#   bin/sync-upstream.sh            # merge, gate, stop before pushing
#   bin/sync-upstream.sh --push     # also push to origin on success
#   bin/sync-upstream.sh --dry-run  # show incoming commits + conflict check only
#
set -euo pipefail

BRANCH="main"
UPSTREAM_REMOTE="upstream"
UPSTREAM_URL="https://github.com/TencentCloud/TencentDB-Agent-Memory.git"

DO_PUSH=0
DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --push)    DO_PUSH=1 ;;
    --dry-run) DRY_RUN=1 ;;
    -h|--help) sed -n '2,32p' "$0"; exit 0 ;;
    *) echo "unknown option: $arg (try --help)" >&2; exit 2 ;;
  esac
done

cd "$(dirname "$0")/.."

say()  { printf '\n\033[1m== %s\033[0m\n' "$*"; }
fail() { printf '\n\033[31mFAIL: %s\033[0m\n' "$*" >&2; exit 1; }

# --- 1. preconditions -------------------------------------------------------
say "Preconditions"

current_branch="$(git rev-parse --abbrev-ref HEAD)"
[ "$current_branch" = "$BRANCH" ] \
  || fail "on branch '$current_branch', expected '$BRANCH'. Switch first."

[ -z "$(git status --porcelain)" ] \
  || fail "working tree is dirty. Commit or stash before syncing."

if ! git remote get-url "$UPSTREAM_REMOTE" >/dev/null 2>&1; then
  echo "adding missing '$UPSTREAM_REMOTE' remote -> $UPSTREAM_URL"
  git remote add "$UPSTREAM_REMOTE" "$UPSTREAM_URL"
fi

echo "branch=$current_branch  clean=yes  upstream=$(git remote get-url $UPSTREAM_REMOTE)"

# --- 2. fetch + report ------------------------------------------------------
say "Fetching upstream"
git fetch "$UPSTREAM_REMOTE" --quiet
git fetch origin --quiet || true

ours_only="$(git rev-list --count "$UPSTREAM_REMOTE/$BRANCH..$BRANCH")"
theirs_only="$(git rev-list --count "$BRANCH..$UPSTREAM_REMOTE/$BRANCH")"

echo "fork is $ours_only commit(s) ahead, $theirs_only commit(s) behind upstream"

if [ "$theirs_only" -eq 0 ]; then
  echo "Already up to date with upstream. Nothing to do."
  exit 0
fi

say "Incoming from upstream ($theirs_only commit(s))"
git log --oneline --no-decorate "$BRANCH..$UPSTREAM_REMOTE/$BRANCH"

say "Files upstream will touch"
git diff --stat "$BRANCH...$UPSTREAM_REMOTE/$BRANCH" | tail -30

# Conflict pre-check that mutates nothing.
say "Conflict pre-check (no changes written)"
if git merge-tree --write-tree "$BRANCH" "$UPSTREAM_REMOTE/$BRANCH" >/tmp/sync-upstream-mt.$$ 2>&1; then
  echo "clean — no conflicts expected"
  conflict_free=1
else
  echo "CONFLICTS expected in:"
  grep -v '^[0-9a-f]\{40\}$' /tmp/sync-upstream-mt.$$ | head -20 || true
  conflict_free=0
fi
rm -f /tmp/sync-upstream-mt.$$

if [ "$DRY_RUN" -eq 1 ]; then
  say "Dry run — stopping before merge"
  exit 0
fi

# --- 3. merge ---------------------------------------------------------------
pre_merge="$(git rev-parse HEAD)"
say "Merging $UPSTREAM_REMOTE/$BRANCH (pre-merge HEAD $pre_merge)"

if ! git merge --no-edit "$UPSTREAM_REMOTE/$BRANCH"; then
  say "Merge conflicted — aborting and restoring pre-merge state"
  git merge --abort || true
  cat >&2 <<EOF

Conflicts must be resolved by hand. The pi adaptation lives in pi-extension/
(which upstream does not have) plus small edits to .gitignore, README.md,
package.json and src/. When resolving, KEEP the fork's pi changes and take
upstream's changes to files we do not modify.

  git merge $UPSTREAM_REMOTE/$BRANCH
  # ...resolve...
  git add -A && git commit
  npm test && npm run build

EOF
  exit 1
fi

# --- 4. gates ---------------------------------------------------------------
gate_failed=0

say "Gate 1/2: npm test"
npm test || gate_failed=1

if [ "$gate_failed" -eq 0 ]; then
  say "Gate 2/2: npm run build"
  npm run build || gate_failed=1
fi

if [ "$gate_failed" -ne 0 ]; then
  say "Gate failed — rolling back to $pre_merge"
  git reset --hard "$pre_merge"
  fail "upstream merge broke tests or the build; fork restored, nothing pushed."
fi

# --- 5. done ----------------------------------------------------------------
say "Sync succeeded"
git log --oneline --no-decorate -1
echo "fork is now $(git rev-list --count "$UPSTREAM_REMOTE/$BRANCH..$BRANCH") ahead, $(git rev-list --count "$BRANCH..$UPSTREAM_REMOTE/$BRANCH") behind upstream"

if [ "$DO_PUSH" -eq 1 ]; then
  say "Pushing to origin/$BRANCH"
  git push origin "$BRANCH"
else
  cat <<EOF

Not pushed (no --push). Review, then:

  git push origin $BRANCH

Reminder: restart pi so the extension picks up merged src/ changes.
EOF
fi
