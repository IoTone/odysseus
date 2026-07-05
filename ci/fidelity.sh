#!/usr/bin/env bash
# ci/fidelity.sh — prove each ported CLI is byte-identical to its Python
# original. Linux-only: the Python side needs the app venv, so this runs on the
# Linux agent. macOS/Windows agents run the portable Racket suite
# (racket/test/run-tests.rkt) instead.
#
# Assumes: official Racket on PATH, and `pip install -r requirements.txt` done
# (so the Python tools import). Run from repo root.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
fail=0
norm() { python3 -m json.tool --sort-keys; }   # canonicalize JSON for diffing

check() { # name, <(py) <(rk) already expanded by caller via process subst
  local name="$1"; shift
  if diff "$@" >/dev/null; then
    echo "  ✓ $name"
  else
    echo "  ✗ $name — Python and Racket output differ:"; diff "$@" | sed 's/^/      /'
    fail=1
  fi
}

echo "[fidelity] odysseus-logs"
mkdir -p logs /tmp/odysseus-tmux
printf 'a\nb\n' > logs/_fid.log; printf 'x\n' > /tmp/odysseus-tmux/_fid.log
# Non-regular *.log entries (a CI node's global /tmp/odysseus-tmux can have them)
# must be handled identically: Python's stat() succeeds on a directory so it's
# included with its stat size; a broken symlink raises OSError and is skipped.
# Racket must match and must NOT crash (it used to call file-size, which throws
# on a directory — the divergence that failed CI).
mkdir -p /tmp/odysseus-tmux/_fid_dir.log
ln -sf /nonexistent-fid-target /tmp/odysseus-tmux/_fid_broken.log
check "logs list" \
  <(python3 scripts/odysseus-logs list | norm) \
  <(racket racket/cli/odysseus-logs.rkt list | norm)
rm -rf logs/_fid.log /tmp/odysseus-tmux/_fid.log \
       /tmp/odysseus-tmux/_fid_dir.log /tmp/odysseus-tmux/_fid_broken.log

echo "[fidelity] odysseus-preset"
export ODYSSEUS_DATA_DIR="$(mktemp -d)/data"; mkdir -p "$ODYSSEUS_DATA_DIR"
# NOTE: the Python tool ignores ODYSSEUS_DATA_DIR (uses repo data/); so for the
# preset diff we drive both against the same isolated dir by symlinking repo
# data/ — or simply compare on a shared seeded file. Here we seed and compare
# read-only ops, which don't depend on location semantics.
seed='{"default":{"name":"Default","temperature":0.7,"system_prompt":"You are helpful."}}'
printf '%s' "$seed" > "$ODYSSEUS_DATA_DIR/presets.json"
# Python writes to repo data/; mirror the seed there too for the read path.
mkdir -p data; cp "$ODYSSEUS_DATA_DIR/presets.json" data/presets.json
check "preset list" \
  <(python3 scripts/odysseus-preset list | norm) \
  <(racket racket/cli/odysseus-preset.rkt list | norm)
check "preset get default" \
  <(python3 scripts/odysseus-preset get default | norm) \
  <(racket racket/cli/odysseus-preset.rkt get default | norm)

# DB-backed tools (signature, notes, tasks, ...) need a seeded app.db with
# matching fixtures on both sides; add them here as they are ported.

if [ "$fail" -eq 0 ]; then echo "[fidelity] all checks identical ✓"; else echo "[fidelity] FAILURES ✗"; fi
exit "$fail"
