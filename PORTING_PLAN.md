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
   library support in Racket).
2. **Each migrated unit is proven by a fidelity diff** against the Python original
   before the Python version is retired (see pass 1 — byte-identical JSON).
3. **The frontend (~140k LOC vanilla JS) is untouched** by the backend port.
   Mobile→Flutter, desktop→`racket/gui` are separate later tracks.

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
1. **Filesystem-only** (no DB/HTTP): `odysseus-logs` ✅, `odysseus-preset` ✅.
2. **DB-backed** (SQLite via `core/db.rkt` ✅): `odysseus-signature` ✅, then
   `odysseus-notes`, `odysseus-tasks`, `odysseus-sessions`, `odysseus-memory`,
   `odysseus-contacts` (these need ORM-model → schema mapping; signature used raw SQL).
3. **HTTP-client** (hit the running app): `odysseus-mail`, `odysseus-calendar`, `odysseus-research`, `odysseus-mcp`.
- Port the git-style dispatcher (`scripts/odysseus`) last; it just execs siblings.
- **Reclassified:** `odysseus-personal` is *not* a thin port — it wraps
  `src/personal_docs.PersonalDocsManager` (stateful RAG index). Moved to **Phase 2**.
- **Exit gate:** every ported CLI passes a byte-identical JSON diff vs Python.
  Where the Python tool needs the full app venv (e.g. DB tools import `core.database`
  → fastapi), that diff runs in **CI** (see Jenkins below); Racket is verified
  standalone against a real SQLite db in the meantime.

### Phase 2 — Symbolic core (`src/` logic → `racket/core/`)
The part that gets *better* in Racket, not just different. ~15–20k LOC of the
40k `src/` is pure logic:
- `tool_schemas.py` / `tool_policy.py` / `tool_parsing.py` → a `define-tool` DSL
  (macros) replacing hand-maintained JSON-schema dicts.
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
- [ ] macOS + Windows build verification (Linux confirmed).
- [ ] Stand up the reverse proxy before Phase 3.
- [ ] Decide email/CalDAV: stay Python services vs. hand-roll in Racket (lean: stay Python).
- [ ] Concurrency spike: one async route ported end-to-end to validate ergonomics.
