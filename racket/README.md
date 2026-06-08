# Odysseus — Racket port

The strangler-fig Racket port of the Python backend. See
[`../PORTING_PLAN.md`](../PORTING_PLAN.md) for strategy and phases, and
[`../porting.md`](../porting.md) for why Racket.

## Layout

    racket/
      info.rkt              package metadata + deps (raco pkg install --auto)
      cli/
        common.rkt          shared CLI scaffolding (port of scripts/_lib/cli.py)
        odysseus-logs.rkt   first ported CLI (filesystem-only) ✅
      server/
        main.rkt            minimal web-server (health endpoint; strangler seed)

## Install Racket

- **Linux (Debian/Ubuntu x86_64 — first target):** official Racket release,
  in-place, no sudo:

      racket/install-racket.sh            # installs to ~/racket
      export PATH="$HOME/racket/bin:$PATH"

  (Not Homebrew on Linux — its `minimal-racket` bottle has a broken `raco exe`.
  Not the Debian `racket` package — split/outdated.)
- **macOS:** `brew install --cask racket` (full) or `brew install minimal-racket`.

## Dev workflow

    # one-time: deps (already done if you ran `raco pkg install`)
    cd racket && raco pkg install --auto

    # byte-compile (catches errors fast)
    raco make cli/*.rkt server/*.rkt

    # run a CLI from source
    racket cli/odysseus-logs.rkt list --pretty

    # run the server
    racket server/main.rkt --port 8099
    curl localhost:8099/health

## Fidelity check (the porting contract)

Every ported CLI must produce byte-identical JSON to its Python original:

    diff <(python3 ../scripts/odysseus-logs list | python3 -m json.tool --sort-keys) \
         <(racket cli/odysseus-logs.rkt list      | python3 -m json.tool --sort-keys)

## Packaging

With the official Racket build (above), both paths are verified working:

    raco exe -o dist/odysseus-logs cli/odysseus-logs.rkt   # standalone binary
    raco distribute dist/bundle dist/odysseus-logs          # relocatable bundle

On Linux, build these with the **official** Racket, not Homebrew (the
`minimal-racket` bottle's `raco exe` segfaults — see PORTING_PLAN.md "Packaging").
