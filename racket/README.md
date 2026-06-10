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
      domain/
        {notes,sessions}.rkt        shared logic (CLI + HTTP routes)
        tools/                      define-tool DSL + native-call → ToolBlock converter
        agent/                      loop spine + OpenAI LLM adapter + tool dispatcher
      cli/
        odysseus-logs.rkt        filesystem ✅   odysseus-notes.rkt     DB ✅
        odysseus-preset.rkt      JSON file ✅    odysseus-sessions.rkt  DB ✅
        odysseus-research.rkt    JSON files ✅   odysseus-tasks.rkt     DB ✅
        odysseus-signature.rkt   SQLite ✅       odysseus-mcp.rkt       DB ✅
        odysseus-calendar.rkt    SQLite ✅       odysseus-agent.rkt     agent ✅
      server/
        main.rkt                    web-server: /health, /api/notes, /api/sessions
        proxy.rkt                   strangler reverse proxy (RACKET_PREFIXES → Racket, rest → Python)
        concurrency-demo.rkt        proof: native evented I/O, no libuv
      test/run-tests.rkt            portable rackunit suite (21 cases)
      info.rkt                      the app package

## Install Racket

- **Nix / NixOS (most reproducible — recommended if you have Nix):** the
  `flake.nix` at the repo root provides everything; no `install-racket.sh` and no
  `raco pkg install` needed. See [Nix / NixOS](#nix--nixos) below.
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

## Nix / NixOS

The root `flake.nix` uses nixpkgs' full Racket (web-server/db/rackunit bundled)
and resolves the local `pkgs/*` via `PLTCOLLECTS` — so there's no `raco pkg
install` step. From the repo root:

    nix develop                      # dev shell: racket + tools, kits on PLTCOLLECTS
    nix build .#odysseus             # build CLIs+server (runs the test suite!) -> ./result/bin
    nix run .#odysseus-logs -- list  # run a CLI directly
    nix profile install .#odysseus   # install odysseus-* onto your PATH

`nix build` runs `racket/test/run-tests.rkt` in its `checkPhase`, so a green
build *is* a passing test run. Installed commands are wrappers around nixpkgs'
`racket` (no `raco exe`), which is bulletproof on Nix's read-only store.

## Dev workflow

> On Nix, skip this — `nix develop` already sets everything up.
>
> **All commands below start from the repo ROOT.** The one-time package install
> uses `racket/pkgs/...` paths; then you `cd racket` once and stay there for
> build/run/test.

    # one-time (from repo root): link the local packages (editable).
    # Official Racket bundles web-server/db/rackunit — install only if missing
    # (a minimal Racket needs them; installing a bundled pkg errors "wider scope"):
    racket -e "(require web-server/servlet-env db rackunit)" 2>/dev/null || raco pkg install --auto web-server-lib db-lib
    raco pkg install --link racket/pkgs/cli-kit racket/pkgs/db-kit racket/pkgs/web-kit

    # everything else runs from racket/ — cd once:
    cd racket

    # byte-compile (bash globs auto-include new files; on Windows/PowerShell use
    # the explicit list in VALIDATION.md — PowerShell doesn't expand *.rkt)
    raco make config.rkt cli/*.rkt domain/*.rkt server/*.rkt test/*.rkt

    racket test/run-tests.rkt                 # the suite (expect: 21 success(es))
    racket cli/odysseus-logs.rkt list --pretty
    racket cli/odysseus-calendar.rkt calendars --pretty   # DB CLI example
    racket server/main.rkt --port 8099 &      # then: curl localhost:8099/{health,api/notes}

## Running the agent against a local LLM

`cli/odysseus-agent.rkt` drives any OpenAI-compatible `/v1/chat/completions`
endpoint. To run fully offline with [ollama](https://ollama.com):

    # ollama MUST be >= 0.3.0 — older builds silently ignore `tools` (no tool_calls).
    ollama --version
    ollama pull qwen2.5:7b                     # minimal model (see note below)

    LLM_ENDPOINT=http://127.0.0.1:11434/v1/chat/completions LLM_MODEL=qwen2.5:7b \
      racket cli/odysseus-agent.rkt "list the .rkt files here, how many?" --pretty
    # add --stream for live SSE output (content chunks -> stderr)

**Minimal model: `qwen2.5:7b`.** `qwen2.5:3b` is marginal — it handles a system
prompt with up to ~7 tools, but returns empty content with the full agent prompt
+ the full toolset. Larger / hosted models (gpt-4o, etc.) work via the same flags
plus `OPENAI_API_KEY`.

DB-backed tools (`manage_notes`, `manage_tasks`, `manage_endpoints`,
`manage_mcp`, `manage_webhooks`, `manage_tokens`, `manage_documents`,
`manage_settings`) operate on the app database (`DATABASE_URL`, default
`data/app.db`) and `data/settings.json`; `manage_skills` works on the SKILL.md
library under `data/skills/`. Run `racket test/seed-db.rkt` first on a fresh
checkout to create the DB schema. Pass `--owner <user>` to act as an identity
(the CLI analog of the `X-Odysseus-User` trusted header) — documents are
strictly owner-scoped and invisible without it.

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

    raco make config.rkt cli/*.rkt domain/*.rkt server/*.rkt test/*.rkt   # 1. compiles?
    racket test/run-tests.rkt                                # 2. behavior (21 tests)
    ../ci/fidelity.sh                                        # 3. byte-identical to Python (from repo root)

For hands-on, step-by-step verification (CLIs, server, packaging, fidelity,
cross-platform) open **`test-plan-manual.html`** in a browser — an interactive
checklist that saves your pass/fail/notes locally and exports a results JSON.
