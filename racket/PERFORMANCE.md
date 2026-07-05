# Performance — measuring & the small-host story

Two costs dominate the agent, and they scale completely differently across
hardware, so the bench measures them **separately** (`racket/test/bench.sh`):

| Cost | What it is | Scales with |
|---|---|---|
| **Agent overhead** | Racket startup + loop + tool dispatch + on-disk SQLite | CPU single-thread + disk; *model-independent* |
| **LLM inference** | tokens/sec + model load | RAM bandwidth + GPU/accelerator; *dominates wall-clock* |

The port's own overhead is tiny and roughly constant; the model is essentially
all of the user-visible latency. A slow host doesn't need a faster *port* — it
needs a *capable-enough model* that still *fits*, plus a trimmed toolset
(`--tools`) and deterministic decoding (`--temperature 0`, now the default).

## How to measure (run on each machine)

```bash
racket/test/bench.sh                                # sections A–D, locally
BENCH_MODELS="qwen2.5:1.5b" racket/test/bench.sh    # just one model for D
```

- **A. host** — uname / cores / RAM / racket version.
- **B. racket startup** — interpreter cold start per CLI call. Each `odysseus-*`
  invocation pays it; on a Pi it's the floor on responsiveness. Mitigate with
  `raco exe` (standalone binary, faster start) or a resident agent process.
- **C. agent round vs a mock LLM** — the real loop (LLM HTTP adapter →
  tool-call protocol → exec → SQLite) with the **model factored out** (a
  deterministic mock answers instantly). This is the port's own cost.
- **D. LLM inference** — `tok/s`, load time, on-disk size per pulled model via
  ollama `/api/generate`. The number that dominates.

Paste each machine's output under the matching column below.

## The three target machines

| Machine | LLM acceleration | Notes |
|---|---|---|
| **Gaming laptop (x86_64 + dGPU)** | CUDA/ROCm offload | 7–14B fast; bound by VRAM |
| **Apple silicon (M-series)** | Metal, unified memory | 7–14B fast; bound by unified RAM |
| **Raspberry Pi 4 (ARM, 4 GB)** | **none** — CPU only, ~4–6 GB/s RAM | memory-bandwidth bound; see below |

Inference on the Pi is **memory-bandwidth bound**: a Q4 model reads ~its whole
size from RAM per token, so `tok/s ≈ usable_bandwidth ÷ model_bytes`. The Pi 4's
~4–6 GB/s ⇒ Q4 3B (~1.9 GB) ≈ **1.5–2.5 tok/s**, Q4 1.5B (~1 GB) ≈ **3–5 tok/s**.

### Measured — gaming-laptop class (x86_64, RTX 3080 Ti 12 GB, 8 cores, 31 GB)

```
B. racket startup     : ~0.29 s cold (per CLI call)
C. agent round (mock) : ~0.36 s full run, ~0.07 s loop-only (model factored out)
D. LLM inference (GPU-accelerated tok/s — a Pi 4 is CPU-only, far slower):
     model          on-disk(Q4)   GPU tok/s   Pi 4 est. (CPU)
     qwen2.5:0.5b    0.37 GB        ~297         ~8–15 tok/s
     qwen2.5:1.5b    0.92 GB        ~240         ~3–5  tok/s
     qwen2.5:3b      1.80 GB        ~180         ~1.5–2.5 tok/s
     qwen2.5:7b      4.36 GB        ~121         (does not fit in 4 GB)
```

> The port overhead (~70 ms/round) is **~3 orders of magnitude** below model
> inference even on this GPU — the model is the whole story. A CPU-only laptop
> (no offload) lands far closer to the Pi than to these GPU numbers.

## Tool-calling reliability vs model size (the part that actually matters)

Emitting a tool call and *filling its arguments correctly* are different
abilities, and the small models have only the first. Measured through the **real
agent** at `--temperature 0`, 3 runs each, "created" = the row actually landed
in SQLite:

| Model | emits tool call | completes a **simple** op (1 tool, flat args) | completes a **complex** op (3 tools, nested `checklist_items`) |
|---|---|---|---|
| `qwen2.5:0.5b` | 3/3 | 0/3 | 0/3 |
| `qwen2.5:1.5b` | 3/3 | 0/3 | 0/3 |
| `qwen2.5:3b` | 3/3 | **3/3** | 0/3 |
| `qwen2.5:7b` | 3/3 | 3/3 | **3/3** |

Two findings fell out of this and are now baked into the agent:

- **`--temperature 0` is the default.** At the provider default (~0.7) even the
  *emission* is flaky — qwen2.5:1.5b tool-called 3/5 at 0.7 vs 5/5 at 0. Tool
  selection should be deterministic; override with `--temperature N`.
- **`--tools` trimming** — fewer schemas in the prompt means a small model
  chooses correctly *and* processes less per turn.

## Smallest LLM that still *functions* on a 4 GB Raspberry Pi 4

**Budget.** 4 GB − ~0.7–1 GB OS ≈ **~3 GB** for model + runtime. That excludes
7B Q4 (~4.4 GB). Of what fits:

- **`qwen2.5:3b` (Q4, ~1.9 GB) is the smallest that actually *completes* tasks**
  — but only **simple** ones: a single `--tools` selection, flat arguments,
  explicit phrasing (measured 3/3). It fits 4 GB (tight — close other apps),
  runs ~1.5–2.5 tok/s, and **fails on nested arguments (checklists) or
  multi-tool selection** (0/3). Demo-grade, not dependable.
- `qwen2.5:1.5b` / `0.5b` **fit easily and call tools, but botch the arguments**
  (0/3 even on a flat note) — so they don't "function" in the complete-the-task
  sense. Useful only for a single hard-wired tool where you post-validate args.

**The honest bottom line:** the smallest model that *reliably* drives the agent
across real (nested / multi-tool) tasks is **`qwen2.5:7b`**, and it needs
~5–6 GB — i.e. an **8 GB Pi 4 / Pi 5**, not a 4 GB Pi 4. On a 4 GB Pi 4 the
realistic ceiling is `qwen2.5:3b` for **simple, single-tool, explicitly-phrased**
operations:

```bash
LLM_ENDPOINT=http://127.0.0.1:11434/v1/chat/completions LLM_MODEL=qwen2.5:3b \
  racket cli/odysseus-agent.rkt "add a note: title Groceries, content buy milk" \
  --owner me --tools manage_notes --temperature 0
```

**Make a small host usable, not just runnable:**
- `--tools` to the few a task needs; `--temperature 0` (default) for determinism.
- `raco exe` the CLI (skip racket cold-start per call) or run a resident agent.
- Q4_K_M quantization only; Q8/FP16 won't fit.
- The ML moat (embeddings/vision/etc.) never runs on the Pi — it stays behind
  HTTP on a real host (see PORTING_PLAN). The Pi runs the agent + tools only.
