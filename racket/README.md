# Odysseus — Racket port

The strangler-fig Racket port of the Python backend. See
[`../PORTING_PLAN.md`](../PORTING_PLAN.md) for strategy and phases, and
[`../porting.md`](../porting.md) for why Racket.

## Layout

A monorepo of independently-installable Racket packages. The `pkgs/*` are
generic and could each be **spun out and published** as a standalone library;
the app depends on them.

    racket/
      pkgs/                         ← spin-out-able libraries (own info.rkt each)
        cli-kit/    (require cli-kit)  generic JSON-CLI scaffolding: emit/fail/run
        db-kit/     (require db-kit)   generic sqlite DATABASE_URL → connection
        web-kit/    (require web-kit)  thin JSON-API wrapper over web-server
      config.rkt                    app-only glue (repo paths, version, app db)
      cli/
        odysseus-logs.rkt           filesystem CLI ✅
        odysseus-preset.rkt         JSON-file CLI ✅
        odysseus-signature.rkt      SQLite CLI ✅ (uses db-kit)
      server/
        main.rkt                    web-server health endpoint (uses web-kit)
        concurrency-demo.rkt        proof: native evented I/O, no libuv
      test/run-tests.rkt            portable rackunit suite
      info.rkt                      the app package

## Install Racket

- **Linux (Debian/Ubuntu x86_64 — first target):** official Racket release,
  in-place, no sudo:

      racket/install-racket.sh            # installs to ~/racket
      export PATH="$HOME/racket/bin:$PATH"

  (Not Homebrew on Linux — its `minimal-racket` bottle has a broken `raco exe`.
  Not the Debian `racket` package — split/outdated.)
- **macOS:** `brew install minimal-racket` (or `brew install --cask racket` for
  the official build; prefer the cask if `raco exe` misbehaves).
- **Windows:** official installer
  `racket-9.2-x86_64-win32-cs.exe` from <https://download.racket-lang.org/>
  (no native ARM build — use x86_64 on Windows-on-ARM).

**Validating on macOS / Windows?** Follow [`VALIDATION.md`](VALIDATION.md) — a
per-OS, copy-paste runbook with expected output.

## Dev workflow

    # one-time: catalog deps + link the local packages (editable)
    raco pkg install --auto --skip-installed web-server-lib db-lib
    raco pkg install --link pkgs/cli-kit pkgs/db-kit pkgs/web-kit

    # byte-compile (explicit entry points — also works in PowerShell, no globbing)
    cd racket && raco make config.rkt cli/odysseus-logs.rkt cli/odysseus-preset.rkt \
                          cli/odysseus-signature.rkt server/main.rkt test/run-tests.rkt

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

## Verify locally

Fastest signal → fullest:

    raco make cli/*.rkt server/*.rkt core/*.rkt test/*.rkt   # 1. compiles?
    racket test/run-tests.rkt                                # 2. behavior (3 tests)
    ../ci/fidelity.sh                                        # 3. byte-identical to Python (from repo root)

For hands-on, step-by-step verification (CLIs, server, packaging, fidelity,
cross-platform) open **`test-plan-manual.html`** in a browser — an interactive
checklist that saves your pass/fail/notes locally and exports a results JSON.
