#!/usr/bin/env bash
# ci/sync-upstream.sh — nightly upstream-drift detector for the Racket port.
#
# Keeps `racket-port` honest against a moving `dev` WITHOUT a human babysitting
# every upstream merge. It is fully NON-DESTRUCTIVE: it fetches the latest
# upstream branch, attempts the merge IN A THROWAWAY GIT WORKTREE (your checkout
# is never touched, nothing is ever pushed), then runs the fidelity canary so
# schema/behavior drift surfaces as a red build the morning after upstream
# changes — not months later at the next manual sync.
#
# What it proves, in order (cheapest signal first):
#   1. does dev still MERGE cleanly into racket-port?        (conflict = stop)
#   2. do the tool SCHEMAS still match Python?  (ci/fidelity-tools.sh, the canary
#      that caught the bash/web_fetch drift after the last big merge)
#   3. does the whole port still BUILD + pass the suite?     (nix flake check)
#
# Exit codes:
#   0  in sync, or the merge is clean AND fidelity-green   → safe to sync for real
#   1  merge conflict, OR fidelity/flake drift             → needs porting work
#   2  setup error (fetch/worktree failed)
#
# Run locally any time:   nix develop --command bash ci/sync-upstream.sh
# Overrides:  REMOTE=origin UPSTREAM_BRANCH=dev PORT_BRANCH=racket-port
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"
REMOTE="${REMOTE:-origin}"
UPSTREAM_BRANCH="${UPSTREAM_BRANCH:-dev}"
PORT_BRANCH="${PORT_BRANCH:-racket-port}"

say(){ echo "[sync] $*"; }

# A Jenkins checkout can be shallow; merge-base + rev-list need real history.
if [ "$(git rev-parse --is-shallow-repository 2>/dev/null)" = "true" ]; then
  say "unshallowing for an accurate merge-base…"
  git fetch -q --unshallow "$REMOTE" 2>/dev/null || true
fi
git fetch -q "$REMOTE" "$UPSTREAM_BRANCH" "$PORT_BRANCH" || { say "fetch failed"; exit 2; }

UP="$(git rev-parse "$REMOTE/$UPSTREAM_BRANCH")"   || exit 2
PORT="$(git rev-parse "$REMOTE/$PORT_BRANCH")"     || exit 2

behind="$(git rev-list --count "$PORT..$UP")"
say "$REMOTE/$PORT_BRANCH is $behind commit(s) behind $REMOTE/$UPSTREAM_BRANCH"
if [ "$behind" -eq 0 ]; then say "already in sync — nothing to check"; exit 0; fi
say "new upstream commits to absorb:"
git log --oneline --no-decorate "$PORT..$UP" | sed 's/^/    /'

# Throwaway worktree off the latest port tip; merge upstream into it.
WT="$(mktemp -d)"
trap 'git worktree remove --force "$WT" >/dev/null 2>&1; rm -rf "$WT"' EXIT
git worktree add -q --detach "$WT" "$PORT" || { say "worktree add failed"; exit 2; }
cd "$WT"

say "attempting merge of $REMOTE/$UPSTREAM_BRANCH into a throwaway $PORT_BRANCH worktree…"
if ! git merge --no-edit --no-ff "$UP" >/dev/null 2>&1; then
  say "MERGE CONFLICT — these paths need a human:"
  git diff --name-only --diff-filter=U | sed 's/^/    /'
  git merge --abort
  exit 1
fi
say "merge is clean (no conflicts)"

rc=0
# (2) the canary: tool-schema byte-identity. python3 stdlib only, fast, the
#     single highest-signal check for "upstream changed a tool".
if command -v python3 >/dev/null; then
  if bash ci/fidelity-tools.sh; then
    say "schema fidelity GREEN against merged upstream"
  else
    say "schema fidelity RED — upstream changed a tool schema; re-baseline the Racket DSL"
    rc=1
  fi
else
  say "[skip] python3 unavailable — schema fidelity not run"
fi

# (3) the full gate: does the merged port still build + pass the suite?
if command -v nix >/dev/null; then
  if nix flake check -L; then say "nix flake check GREEN on the merged tree"
  else say "nix flake check RED — the merge breaks the build/suite"; rc=1; fi
else
  say "[skip] nix unavailable — flake check not run"
fi

echo
if [ "$rc" -eq 0 ]; then
  say "DRIFT CHECK PASSED — $behind upstream commit(s) merge cleanly and stay fidelity-green."
  say "Safe to sync for real:  git checkout $PORT_BRANCH && git merge $REMOTE/$UPSTREAM_BRANCH"
else
  say "DRIFT CHECK FAILED — port the delta above before merging $UPSTREAM_BRANCH."
fi
exit "$rc"
