# Local Mac Setup — All-Local Quick Start

Run Odysseus on a Mac with **no external API calls** — everything points at a
local model via [ollama](https://ollama.com). Two layers, depending on what you
want to do:

- **[A. Run the product](#a-run-the-product-all-local)** — the full web app (chat,
  agents, notes, calendar, …). This is what you *use*.
- **[B. Run the Racket agent](#b-run-the-racket-agent-the-port)** — the ported
  agent CLI. This is the strangler-port work, for development/fidelity.

See also: the general [Setup Guide](setup.md) and [CONTRIBUTING.md](../CONTRIBUTING.md).

---

## Prerequisite: a local model daemon

```bash
brew install ollama
ollama serve                  # runs on 127.0.0.1:11434
ollama pull qwen2.5:14b       # full 20-tool agent sweet spot
# qwen2.5:7b also works but is marginal at the full toolset: tool calls fire
# fine, but the final text answer can come back empty.
```

Leave `ollama serve` running in its own terminal (or `brew services start ollama`).

---

## A. Run the product (all-local)

The full product ships as the Python app via Docker. "All-local" just means
pointing it at the local ollama instead of a hosted API.

```bash
cd <your-odysseus-clone>
docker compose up -d --build
docker compose logs odysseus | grep -i password   # first admin password
```

Open **http://localhost:7000**, log in with that password (change it in
**Settings**), then add a local endpoint under **Settings → Models**:

| Field    | Value                                       |
|----------|---------------------------------------------|
| Base URL | `http://host.docker.internal:11434/v1`      |
| Model    | `qwen2.5:14b`                               |

> **Why `host.docker.internal` and not `localhost`?** ollama runs on the *host*;
> the app runs in a *container*. From inside the container, `localhost` is the
> container itself — `host.docker.internal` is how it reaches the Mac's ollama.

That's the complete product, fully offline.

### Alternative: Apple `container` instead of Docker (macOS 26+)

You don't strictly *need* Docker for this tier. None of the four services
(app + chromadb + searxng + ntfy) touch the GPU — the accelerated model runs
natively on the host and is reached over HTTP — so they run fine under Apple's
first-party [`container`](https://github.com/apple/container). That's exactly the
topology [`apple-ml-containers.md`](../apple-ml-containers.md) argues for: GPU
work stays native, everything else can be containerized. Verified end-to-end
against `container` 1.0.0 (all four services up, app reaching chromadb/searxng
over the container network, login page served on :7000).

One-time host setup on a clean macOS 26 box:

```bash
brew install container
container system start                              # installs a Linux kernel on first run
softwareupdate --install-rosetta --agree-to-license # buildkit needs Rosetta to build the app image
```

Then run the stack:

```bash
OLLAMA_HOST=0.0.0.0 ollama serve          # bind beyond loopback (see caveat below)
scripts/apple-container-stack.sh up        # build image + start all 4 services
scripts/apple-container-stack.sh password  # first admin password
# open http://127.0.0.1:7000 ; then:  scripts/apple-container-stack.sh down
```

> **Use `127.0.0.1`, not `localhost`.** macOS AirPlay Receiver listens on
> `*:7000` including IPv6 `::1`, so `localhost:7000` (which resolves IPv6-first)
> can hit AirPlay's `403` instead of the app — the container publishes on
> `127.0.0.1` only. Either browse to `http://127.0.0.1:7000`, disable
> **System Settings → General → AirDrop & Handoff → AirPlay Receiver**, or set
> `APP_PORT=` to a non-7000 port. (This bites the Docker path on port 7000 too.)

> **ollama networking caveat.** Apple `container` has no `host.docker.internal`.
> Each container is its own lightweight VM, so it reaches the Mac at the host's
> LAN IP, *not* loopback — and ollama binds `127.0.0.1` by default. Start it with
> `OLLAMA_HOST=0.0.0.0 ollama serve` so the container can reach it. The script
> auto-detects the host IP (override with `HOST_IP=`) and points the app there.

Why this stays an *alternative* and Docker remains the default: Apple `container`
1.0.0 has no `compose`, so the script hand-rolls what compose does for free —
and running it live surfaced real gaps it has to paper over:

- **No name-based DNS** without a `sudo`-created `container system dns` domain, so
  the script resolves each peer's per-network IP and injects it into the app
  (compose just used `http://searxng:8080`). Trade-off: if you later restart
  chromadb/searxng alone, its IP changes and you must re-run `up`.
- **Occasional "no route to host"** on a freshly-attached container even though
  it's "running" — the script gates on reachability and restarts the peer once
  to clear it.
- Plus macOS 26 + Rosetta + a kernel install, startup ordering via healthcheck
  polls, named-volume → `./data` bind dirs, and the searxng first-boot wrapper.

Docker/colima remain the lower-friction path (real `compose`, name DNS,
`host.docker.internal`, older macOS). The script's header documents every
compose-ism it translates.

---

## B. Run the Racket agent (the port)

The Racket strangler runs *next to* the app and consumes its database. Most
reproducible path is the Nix flake (same toolchain CI uses — full Racket +
python3 + sqlite):

```bash
cd <your-odysseus-clone>
nix develop                   # racket + python3 + sqlite + curl on PATH

cd racket
racket test/run-tests.rkt     # expect "24 success(es)" — confirms the toolchain
racket test/seed-db.rkt       # creates ./data/app.db (the port consumes the app
                              # DB but doesn't own the DDL, so seed it on a fresh box)

# Drive the agent against local ollama, all-local:
LLM_ENDPOINT=http://127.0.0.1:11434/v1/chat/completions LLM_MODEL=qwen2.5:14b \
  racket cli/odysseus-agent.rkt \
    "add a checklist note titled Groceries with milk and eggs" \
    --owner alice --pretty
```

Notes:
- From the bare CLI, ollama is at `127.0.0.1:11434` (no `host.docker.internal` —
  that's only for the containerized product in section A).
- `--owner NAME` is the CLI analog of the trusted `X-Odysseus-User` header;
  without it, owner-scoped data (documents, etc.) behaves like the `owner=None`
  path. Add `--stream` for SSE, `--max-rounds N` to bound the agent loop.

### No Nix?

Use Homebrew's **full** Racket cask (not `minimal-racket` — its `raco exe`
segfaults on macOS; run-from-source is fine either way):

```bash
brew install --cask racket
cd <your-odysseus-clone>/racket
export PLTCOLLECTS="$PWD/pkgs:"     # makes cli-kit/db-kit/web-kit resolvable
# then the same `racket test/...` and `racket cli/...` commands as above
```

### Full end-to-end check

One command runs compile → unit suite → mock end-to-end → live ollama:

```bash
cd racket
OLLAMA=1 ./test/integration.sh     # drop OLLAMA=1 to make the live stage optional
```
