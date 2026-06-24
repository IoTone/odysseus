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
