# Small-Host / ARM64 SBC Profile — Raspberry Pi 5 & MTK Genio 720

Running Odysseus on an 8 GB ARM64 single-board computer. **Baseline: Raspberry
Pi 5 (8 GB). Target: MTK Genio 720 (8 GB).** Both are ordinary `aarch64-linux`
machines to us — you run the stack under **Docker or Podman** (Apple `container`
is macOS-only; see [`local-mac.md`](local-mac.md) for that path).

See also: [`../NIX_DEPLOYMENT.md`](../NIX_DEPLOYMENT.md) (which already treats the
Genio 720 as a first-class `aarch64-linux` target) and
[`../racket/PERFORMANCE.md`](../racket/PERFORMANCE.md) (the measured small-host
numbers this page builds on).

---

## The one principle: the model dominates

Everything except the LLM is cheap and CPU-only. The product tier is four light
services — the FastAPI app, plus optional chromadb / searxng / ntfy — and the
app itself is a few hundred MB of RAM. **All of the user-visible latency, and
almost all of the RAM pressure, is the model.** So sizing a small host is really
two independent questions:

1. **The product tier** — trivially fits any 8 GB SBC (and the minimal profile
   fits far less).
2. **The model** — the real constraint, and the thing that decides whether you
   run it *on the box* or *offload it over HTTP*.

The HTTP seam between them is what makes both topologies below possible.

> **NPU/GPU note.** Neither the Pi 5's VideoCore GPU nor the Genio 720's NPU is
> usable by CPU LLM runtimes (ollama / llama.cpp) out of the box — inference is
> **memory-bandwidth-bound on the CPU**. `NIX_DEPLOYMENT.md` says the same about
> the Genio's APU: "irrelevant to us." Treat these boards as fast CPUs with no
> LLM accelerator.

---

## Two topologies

### A. Offload the model (recommended — full agent quality)

The SBC runs the product; the model runs on a LAN GPU box or a hosted API,
reached over HTTP. The board barely works, and you get whatever model quality
the remote can serve (e.g. `qwen2.5:14b`, the full-toolset sweet spot).

```
  ARM64 SBC (Pi 5 / Genio 720)              LAN GPU box / hosted API
  ┌───────────────────────────┐            ┌──────────────────────────┐
  │ odysseus app + services   │ ──HTTP──▶  │ ollama / vLLM (GPU)      │
  │ SQLite, FastEmbed (CPU)    │  OpenAI    │ qwen2.5:14b, fast        │
  └───────────────────────────┘  -compat   └──────────────────────────┘
```

This is the sweet spot for an 8 GB board: the model — the only heavy part —
isn't on it at all.

### B. All-on-the-box (self-contained, offline)

The SBC runs everything, model included, via ollama on CPU. Works, but the model
is capped by RAM and memory bandwidth — see the tiers below.

---

## Model tiers on the box (the actual limit)

Measured on a **Pi 4 (4 GB, CPU-only)** through the real agent loop
(`racket/PERFORMANCE.md`), then extrapolated to the 8 GB boards. Capability is
measured, tok/s for Pi 5 / Genio 720 is **estimated** by memory bandwidth
(`tok/s ≈ usable_bandwidth ÷ model_bytes`) — run the bench (below) for truth.

| Model (Q4) | Size | Chat | 1 tool | Multi-step | Pi 4 tok/s (meas.) | Pi 5 / Genio 720 est. |
|---|---|---|---|---|---|---|
| `qwen2.5:1.5b` | ~1.0 GB | ✅ | ✗ | ✗ | ~3–5 | ~8–13 |
| `qwen2.5:3b` | ~1.8 GB | ✅ | ✅ | ✗ | ~1.5–2.5 | ~4–7 |
| `qwen2.5:7b` | ~4.4 GB | ✅ | ✅ | ✅ | doesn't fit in 4 GB | ~2–3 |

**Reading this for an 8 GB board:**

- **`qwen2.5:7b` fits** (stack ~1.5–2 GB + 4.4 GB model + headroom) and is the
  **first tier that handles the multi-step agent** — but only ~2–3 tok/s, i.e.
  usable-but-slow. Best paired with `--tools` trimming (small models choke on the
  full 20-tool prompt; `local-mac.md` flags even 7B as "marginal" there).
- **`qwen2.5:3b`** is the snappy default (~4–7 tok/s) for chat + single-tool use;
  it does **not** reliably do multi-step tool chains.
- **4 GB variants** (either board): `qwen2.5:3b` is the practical ceiling, and
  single-tool only — same story as the Pi 4.

**Genio 720 vs Pi 5:** the Genio's Cortex-A78 cores and (if fitted) LPDDR5 give
it somewhat more memory bandwidth than the Pi 5's A76 + LPDDR4X, so expect it to
land at or slightly above the Pi 5 column. Same tiers, a bit faster — but still
CPU/bandwidth-bound, so the 7B ≈ "slow but works" conclusion holds.

---

## Quick start

### Minimal (app-only) — [`../docker-compose.pi.yml`](../docker-compose.pi.yml)

Just the app + an LLM endpoint. chromadb / searxng / ntfy are omitted; the app
degrades gracefully (keyword memory, no web search, no push).

```bash
# On-box small model:
OLLAMA_HOST=0.0.0.0 ollama serve        # in its own terminal
ollama pull qwen2.5:3b

docker compose -f docker-compose.pi.yml up -d --build
docker compose -f docker-compose.pi.yml logs odysseus | grep -i password
# open http://127.0.0.1:7000
docker compose -f docker-compose.pi.yml down
```

To **offload** the model (topology A) instead, set the endpoint to your remote
box and skip local ollama entirely:

```bash
OLLAMA_BASE_URL=http://192.168.1.50:11434/v1 LLM_HOST=192.168.1.50 \
  docker compose -f docker-compose.pi.yml up -d --build
```

### Full stack on the SBC

The normal compose file is already arm64-native — just choose a small model:

```bash
docker compose up -d --build             # app + chromadb + searxng + ntfy
```

Point **Settings → Models** at your model as usual (host ollama at
`http://host.docker.internal:11434/v1`, or a LAN/remote endpoint).

---

## Get real numbers before committing

The estimates above are extrapolated from Pi 4 measurements. The repo ships a
bench harness — run it **on the actual board** to replace the guesses with host
specs + per-model tok/s + fit:

```bash
BENCH_MODELS="qwen2.5:3b,qwen2.5:7b" racket/test/bench.sh
```
