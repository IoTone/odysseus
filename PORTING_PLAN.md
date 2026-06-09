# Odysseus → Racket: Porting Plan

Companion to [`porting.md`](porting.md) (the language analysis). That doc decided
**Racket**; this one is the execution plan. FreeBSD is a *possibility, not a
priority* — so Racket's only soft spot is de-prioritized and the pick stands.

Target platforms (priority order): **Linux, macOS, Windows** — FreeBSD best-effort.

## Guiding strategy: strangler fig

We do **not** rewrite 136k lines in one go. We stand a Racket process next to the
Python FastAPI app and migrate capability-by-capability behind a reverse proxy,
keeping the app shippable the entire time. Three permanent rules:

1. **The ML/native moat stays Python, forever, behind HTTP.** `fastembed`,
   `torch`, `diffusers`, `PyMuPDF`, `chromadb`, `faster-whisper` have no Racket
   equivalent. `scripts/diffusion_server.py` is the pattern: small Python service,
   stable JSON contract. Email/CalDAV likely stay Python initially too (thin
   library support in Racket). On **macOS** this is mandatory, not just preferred:
   GPU/ANE acceleration is impossible inside any container/VM, so the ML service
   must run **natively** and be reached over HTTP — see
   [`apple-ml-containers.md`](apple-ml-containers.md).
2. **Each migrated unit is proven by a fidelity diff** against the Python original
   before the Python version is retired (see pass 1 — byte-identical JSON).
3. **The frontend (~140k LOC vanilla JS) is untouched** by the backend port.
   Mobile→Flutter, desktop→`racket/gui` are separate later tracks.

## Module structure: a monorepo of spin-out-able packages

Everything generic is built as its own Racket package under `racket/pkgs/`, each
with its own `info.rkt` and independently `raco pkg install`-able — so any of
them can be **spun out and published** as a standalone library later, with no
app entanglement. App-specific glue stays in the app.

| Package | `(require …)` | Generic? | Could publish as |
|---|---|---|---|
| `racket/pkgs/cli-kit` | `cli-kit` | yes | "tiny JSON-CLI toolkit" |
| `racket/pkgs/db-kit` | `db-kit` | yes | "sqlite DATABASE_URL → connection" |
| `racket/pkgs/web-kit` | `web-kit` | yes (thin) | maybe — see note |
| `racket/` (app) | `odysseus/*` | no | n/a (it's the app) |

Rule: a thing graduates to `pkgs/` when it has **zero Odysseus knowledge**.
`config.rkt` (repo paths, app version, app db) is the one app-branded shared
module; the CLIs/server require the kits + `config.rkt`.

On `web-kit` and "is there something better out there": the **server** is
Racket's built-in `web-server` — don't reinvent it. `web-kit` is only a thin
JSON-API wrapper to cut boilerplate. If we ever want a batteries framework
(sessions, migrations, CSRF, components), adopt **`koyo`** rather than growing
`web-kit`. So `web-kit` may never be worth publishing — that's fine; it stays a
package so the *option* exists and the app's web glue is cleanly isolated.

## Phases

### Phase 0 — Toolchain & scaffold ✅ (done in pass 1)
- **Supported toolchain: official Racket 9.2 [cs]** from racket-lang.org,
  installed in-place under `~/racket` (no sudo) via `racket/install-racket.sh`.
  Full-featured (includes GUI for Phase 4) and — unlike the Homebrew
  `minimal-racket` bottle — a **working `raco exe`** (see Packaging).
  Homebrew remains the macOS path only.
- `racket/` project: `info.rkt`, `cli/`, `server/`; `web-server-lib` + `db-lib` installed.
- Shared CLI lib + first CLI ported + minimal server, all compiling & running.

### Phase 1 — The CLIs (`scripts/` → `racket/cli/`)  ← current
~30 `odysseus-*` tools, ~4k LOC. Self-contained, lowest risk, perfect for
hardening the toolchain. Order by dependency weight:
1. **Filesystem-only** (no DB/HTTP): `odysseus-logs` ✅, `odysseus-preset` ✅,
   `odysseus-research` ✅ (JSON blobs in `data/deep_research/`).
2. **DB-backed** (SQLite via the `db-kit` package ✅): `odysseus-signature` ✅,
   `odysseus-notes` ✅, `odysseus-sessions` ✅, `odysseus-tasks` ✅,
   `odysseus-mcp` ✅, `odysseus-calendar` ✅ (date-range + `is_utc` Z-suffix).
   All raw SQL against the same `DATABASE_URL`; `db-kit` carries shared
   value/`DateTime` coercion so new ones are quick.
   (Note: the "HTTP-client" tier turned out to be a misnomer — none of these hit
   HTTP; they read the DB or files directly.)
- **Deferred:** `odysseus-mail` wraps `routes/email_helpers` + IMAP pollers (the
  email subsystem), not a thin port → with the Phase-2/3 email work.
- Port the git-style dispatcher (`scripts/odysseus`) last; it just execs siblings.
- **Reclassified to Phase 2 (not thin DB ports — they wrap stateful subsystems):**
  `odysseus-personal` (wraps `src/personal_docs` RAG index), `odysseus-memory`
  (wraps `services/memory` ChromaDB/fastembed vector store), and `odysseus-contacts`
  (wraps `routes/contacts_routes` vCard/route helpers, not just the DB).
- **Exit gate:** every ported CLI passes a byte-identical JSON diff vs Python.
  Where the Python tool needs the full app venv (e.g. DB tools import `core.database`
  → fastapi), that diff runs in **CI** (see Jenkins below); Racket is verified
  standalone against a real SQLite db in the meantime.

### Phase 2 — Symbolic core (`src/` logic → `racket/core/`)
The part that gets *better* in Racket, not just different. ~15–20k LOC of the
40k `src/` is pure logic:
- `tool_schemas.py` / `tool_policy.py` / `tool_parsing.py` → a `define-tool` DSL
  (macros) replacing hand-maintained JSON-schema dicts. **✅ Started:**
  `domain/tools/dsl.rkt` (`define-tool` macro: required-by-default params,
  `#:optional`/`#:enum`/`#:items`) + `domain/tools/core-tools.rkt` (10 tools). The
  emitted schemas are **byte-identical to `FUNCTION_TOOL_SCHEMAS`** for all 10
  (verified by `ci/fidelity-tools.sh` via `ast.literal_eval` — no venv) and a
  rackunit case. Compare ~12 declarative lines/tool here vs the nested dicts in
  the 1372-line Python file.
  **✅ Converter too:** `domain/tools/convert.rkt` ports
  `function_call_to_tool_block` (native call → ToolBlock) as a `racket/match` over
  the resolved tool type — the if/elif `args.get(...)` ladder becomes pattern
  matching. Verified against the **live** Python converter (`ci/fidelity-convert.sh`,
  26 cases: type exact, content semantic since Python's `json.dumps` spaces differ)
  + a rackunit case. Remaining: the other ~67 tools + the full alias map / tags
  (mechanical data) + the few custom-assembly branches (ui_control, manage_session).
- `action_intents.py`, `agent_loop.py` (state machine) → `racket/match`.
- `mcp_servers/` (MCP protocol) → Racket structs + JSON.
- Ships as a **library** (so the future desktop GUI can link it directly, not over HTTP).
- **Exit gate:** golden-file tests — same inputs → same tool-call JSON as Python.

### Phase 3 — HTTP surface (`routes/` → `racket/server/`)
~34k LOC of FastAPI endpoints. Migrate **incrementally** behind a reverse proxy:
proxy forwards each path to Python or Racket; flip one route at a time.
- Rebuild Pydantic boundary validation as Racket **contracts**.
- Concurrency: FastAPI `async` → Racket green threads + `sync` events (budget a
  real re-think; one route end-to-end first as a spike).
- **Exit gate:** existing `tests/` (462 files) pass against the Racket route via the proxy.

**✅ Spike done — verified against the REAL app:**
- `domain/{notes,sessions}.rkt` — list query + serialization shared by the CLI
  and the server (one source of truth; CLI and HTTP can't drift).
- `server/main.rkt` serves real `GET /api/notes` and `GET /api/sessions` from the DB.
- `server/proxy.rkt` — hardened strangler proxy (forwards method, path+query,
  request headers, body; returns upstream status + headers + body). Routes
  `/api/notes` + `/api/sessions` → Racket, everything else → the Python app
  (`uvicorn app:app`, default :7000). Caddy equivalent in its header.
- **Booted the actual app** (`.venv` web stack, ChromaDB-degraded) and drove real
  traffic through the proxy: migrated paths → Racket, `/`, `/api/models` → Python.

**Key lesson surfaced — the HTTP contract ≠ the CLI's JSON.** The real route wraps
`{"notes": [...]}`, emits *all* Note columns with `null` (not `""`/`[]`), and
parses `items`. So `domain/notes` now carries **two** serializers: `note->jsexpr`
(CLI tool) and `note->web-jsexpr`/`list-notes-web` (HTTP). `GET /api/notes`
(incl. `?archived`/`?label`) is now **byte-identical to the FastAPI route**
(diffed against the live app). `GET /api/sessions` still returns the CLI shape —
**align it to its web contract before flipping it for real** (same pattern).

To run the strangler locally: `mkdir -p data && AUTH_ENABLED=false .venv/bin/uvicorn
app:app --port 7000`, `racket racket/server/main.rkt --port 8099`, `racket
racket/server/proxy.rkt --port 8080`.

**Route migratability is a spectrum (the real lesson):**
- **Pure-DB routes → clean drop-ins.** `GET /api/notes` reads only the DB; the
  Racket route is byte-identical to FastAPI. These flip easily.
- **Runtime-state routes → not yet.** `GET /api/sessions` reads the in-memory
  `SessionManager` (+ joins documents/gallery, masks model names). Can't be a
  DB-only takeover until that state is DB-derived or the manager is ported. The
  Racket `/api/sessions` is a CLI-shape convenience only and is **not proxied**.
- Triage each route by what it touches before promising a flip.

**Auth as a trusted header (don't port the auth subsystem).** The app resolves
identity in middleware (cookie/token → `request.state.current_user`). Rather than
re-implement that in Racket, the migrated route reads a trusted `X-Odysseus-User`
header set by the upstream auth tier; absent header = no owner filter (=
`AUTH_ENABLED=false`). `GET /api/notes` honors it: verified on the real DB —
no header → all active; `X-Odysseus-User: bob` → only bob's; unknown → none.

**Flipping a route is now config, not code.** `server/proxy.rkt` reads
`RACKET_PREFIXES` (comma-separated; default just `/api/notes`). Promote a route
by adding its prefix once it's a verified drop-in — no recompile.

#### Decision: no libuv FFI — Racket's runtime already IS the event loop
FastAPI's async comes from ASGI → uvicorn → **uvloop (libuv)**. The tempting
move is to FFI libuv into Racket for the same. We will **not**, because:

- **Racket already has it.** Racket CS runs M green threads over its own evented
  scheduler; blocking I/O (`tcp`, `sleep`, `sync`) parks the *green* thread and
  runs others on the same OS thread — the exact uvloop behavior. Proven in
  `racket/server/concurrency-demo.rkt`: **40 concurrent I/O-bound connections in
  ~0.5s (≈38× over sequential) on one OS thread**, zero native deps.
- **libuv FFI fights the portability goal.** It's a C library that must be
  built/linked per platform (Win/Mac/Linux/BSD) — reintroducing exactly the
  native-build pain `raco exe` just removed. Racket's I/O is pure-runtime,
  portable everywhere Racket runs.
- **It's research-grade for negative ROI.** Bridging libuv's callback loop into
  Racket CS means running libuv on a dedicated OS thread and marshaling
  completions back through Racket's event system (foreign callbacks into CS are
  delicate w.r.t. the GC/scheduler). Large, fragile, and pointless on an
  **I/O-bound glue layer** — the heavy compute already lives in the Python ML
  microservices and external LLM APIs, not here.

**So the Racket HTTP layer needs no FFI.** Two native options, both portable:
1. `web-server` (batteries: dispatch, cookies, etc.) — what `server/main.rkt` uses.
2. A lean server on `racket/tcp` + `sync` for maximum control/perf.

We start on (1) and drop to (2) only if a measured need appears.

**And FastAPI fully disappears.** End state: the web layer is 100% Racket; the
only retained Python is ML/PDF microservices, which need a *minimal* HTTP server
(e.g. stdlib `http.server`), not FastAPI either.

### Phase 4 — Desktop client (`racket/gui`)
The payoff: a native desktop app on the shared Phase-2 core, replacing the web
frontend for desktop users. Cross-platform native widgets, no Electron.

## Packaging / distribution (the portability win — resolved in pass 1)

Toolchain policy by OS:

| OS | Toolchain | How |
|---|---|---|
| **Nix / NixOS (most reproducible)** | nixpkgs full Racket via `flake.nix` | `nix develop` / `nix build` / `nix run` / `nix profile install` — no install script, no `raco pkg install` |
| **Linux (Debian/Ubuntu x86_64, first target)** | **Official Racket release** | `racket/install-racket.sh` → in-place under `~/racket`, no sudo |
| **macOS** | Homebrew | `brew install --cask racket` (full) or `minimal-racket` |
| Other Linux / distros | Official `natipkg` build | `RACKET_VARIANT=natipkg racket/install-racket.sh` (explored later) |

**Verified working on official Linux build (pass 1):**
- Run from source (`racket cli/foo.rkt`) and byte-compile (`raco make`) ✓
- **`raco exe`** → standalone ELF binary, runs, byte-identical to Python ✓
- **`raco distribute`** → fully self-contained, relocatable ~56 MB dir, runs ✓

> Historical note: the Homebrew `minimal-racket` bottle's `raco exe` **segfaults**
> (exit 139, even on `--version` — its embedded Racket-CS boot image is
> mis-relocated). That's why Linux uses the official release, not Homebrew or the
> split/outdated Debian `racket` package. These working binaries are what retire
> Odysseus's per-OS shell scripts (`build-macos-app.sh`, `launch-windows.ps1`,
> `update_windows.bat`).

## Definition of done per unit
1. Compiles (`raco make`).
2. Behavior matches Python (fidelity diff / golden test).
3. Runs from source on Linux + macOS (Windows in CI once Phase 1 stabilizes).
4. Python original removed (or proxied) only after 1–3 pass.

## Open items
- [x] Official full Racket on Linux + working `raco exe`/`distribute` (pass 1).
- [ ] Wire `racket/install-racket.sh` into CI for per-platform release builds.
- [x] **macOS + Windows verified by hand** — build, 10/10 suite, and a working
  standalone `raco exe` on both (Windows on Racket 9.1). Three priority OSes
  green; FreeBSD remains a "possibility." (Two cross-platform bugs found & fixed
  in the process: db-kit `#:create-missing?` mode, and POSIX-only absolute-path
  detection on Windows.)
- [x] Strangler reverse proxy stood up (`server/proxy.rkt`), verified vs the live app.
- [ ] Decide email/CalDAV: stay Python services vs. hand-roll in Racket (lean: stay Python).
- [ ] Concurrency spike: one async route ported end-to-end to validate ergonomics.
