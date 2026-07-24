#!/usr/bin/env bash
# ci/sync-upstream.sh — nightly upstream-drift detector for the Racket port.
#
# Watches the TRUE upstream project (pewdiepie-archdaemon/odysseus) — NOT our own
# IoTone fork's `dev`, which is fed *from* racket-port and so can never show
# drift. Keeps `racket-port` honest against a moving upstream without a human
# babysitting every merge.
#
# Fully NON-DESTRUCTIVE: fetches the upstream branch (public, read-only, no
# creds), attempts the merge IN A THROWAWAY GIT WORKTREE (your checkout is never
# touched, nothing is ever pushed), then runs the fidelity canary + build so
# drift surfaces as a red build the morning after upstream changes.
#
# IMPORTANT: this DETECTS and REPORTS drift; it does NOT port anything. A red
# build means "upstream moved — port the delta it lists, then merge."
#
# What it reports, cheapest signal first:
#   0. how far behind upstream is + the backlog (commit list, areas touched)
#   1. does upstream still MERGE cleanly into racket-port?    (conflict = stop)
#   2. do the tool SCHEMAS still match Python?  (ci/fidelity-tools.sh, the canary
#      that caught the bash/web_fetch drift after the last big merge)
#   3. does the whole port still BUILD + pass the suite?      (nix flake check)
#
# Exit codes:
#   0  in sync, or the merge is clean AND fidelity-green   → safe to sync for real
#   1  behind + (merge conflict OR fidelity/flake drift)   → needs porting work
#   2  setup error (fetch/worktree failed)
#
# Run locally any time:   nix develop --command bash ci/sync-upstream.sh
# Overrides:
#   UPSTREAM_URL=https://github.com/pewdiepie-archdaemon/odysseus.git
#   UPSTREAM_BRANCH=dev   PORT_REMOTE=origin   PORT_BRANCH=racket-port
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"
UPSTREAM_URL="${UPSTREAM_URL:-https://github.com/pewdiepie-archdaemon/odysseus.git}"
UPSTREAM_BRANCH="${UPSTREAM_BRANCH:-dev}"
PORT_REMOTE="${PORT_REMOTE:-origin}"
PORT_BRANCH="${PORT_BRANCH:-racket-port}"

say(){ echo "[sync] $*"; }

# A Jenkins checkout of the port can be shallow; merge-base + rev-list need real
# history. Unshallow the port remote, then deepen it in case it was --depth 1.
if [ "$(git rev-parse --is-shallow-repository 2>/dev/null)" = "true" ]; then
  say "unshallowing for an accurate merge-base…"
  git fetch -q --unshallow "$PORT_REMOTE" 2>/dev/null || true
fi
git fetch -q "$PORT_REMOTE" "$PORT_BRANCH" || { say "fetch of $PORT_REMOTE/$PORT_BRANCH failed"; exit 2; }

# Fetch the TRUE upstream branch straight from its URL → lands in FETCH_HEAD.
# Public repo, so no credential wiring; no persistent remote added to the
# workspace. Full history (no --depth) so the merge + merge-base are correct.
say "fetching upstream $UPSTREAM_BRANCH from $UPSTREAM_URL …"
git fetch -q "$UPSTREAM_URL" "$UPSTREAM_BRANCH" || { say "upstream fetch failed"; exit 2; }
UP="$(git rev-parse FETCH_HEAD)"                    || exit 2
PORT="$(git rev-parse "$PORT_REMOTE/$PORT_BRANCH")" || exit 2

behind="$(git rev-list --count "$PORT..$UP")"
say "$PORT_BRANCH is $behind upstream commit(s) behind $UPSTREAM_BRANCH ($(echo "$UP" | cut -c1-9))"
if [ "$behind" -eq 0 ]; then say "already in sync — nothing to check"; exit 0; fi

# --- the backlog report (what a human/agent needs to start porting) ----------
say "backlog: $behind commit(s), $(git rev-list --count --no-merges "$PORT..$UP") non-merge"
say "most recent upstream commits the port is missing:"
git log --oneline --no-decorate "$PORT..$UP" | head -25 | sed 's/^/    /'
[ "$behind" -gt 25 ] && say "    …and $((behind-25)) more"
say "top-level areas upstream touched since the merge-base:"
git diff --name-only "$PORT...$UP" | awk -F/ 'NF>1{print $1"/"$2} NF==1{print $1}' \
  | sort | uniq -c | sort -rn | head -12 | sed 's/^/    /'

# --- can it still merge + stay fidelity-green? -------------------------------
WT="$(mktemp -d)"
trap 'git worktree remove --force "$WT" >/dev/null 2>&1; rm -rf "$WT"' EXIT
git worktree add -q --detach "$WT" "$PORT" || { say "worktree add failed"; exit 2; }
cd "$WT"

say "attempting merge of upstream $UPSTREAM_BRANCH into a throwaway $PORT_BRANCH worktree…"
if ! git merge --no-edit --no-ff "$UP" >/dev/null 2>&1; then
  say "MERGE CONFLICT in $(git diff --name-only --diff-filter=U | wc -l | tr -d ' ') path(s) — a human must resolve. First 20:"
  git diff --name-only --diff-filter=U | head -20 | sed 's/^/    /'
  git merge --abort
  say "DRIFT: $behind commit(s) behind and the merge conflicts — port the delta above, then merge."
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
  say "Safe to sync for real:  git fetch $UPSTREAM_URL $UPSTREAM_BRANCH && git merge FETCH_HEAD"
else
  say "DRIFT CHECK FAILED — port the delta above before merging upstream."
fi
exit "$rc"
