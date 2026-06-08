# Apple ML in a container — investigation

**Question:** Can we run our ML workloads in a container on Apple Silicon, using
Apple's own containerization? **Short answer:** Apple *does* now ship its own
container stack — but **you cannot get GPU/Metal/ANE acceleration inside any
container or VM on macOS.** So accelerated ML must run **natively on the host and
be reached over HTTP** — which is exactly the architecture this port already
mandates for the ML moat.

## What Apple shipped (WWDC 2025)

- **`container` CLI + Containerization framework** — open-source Swift, on
  macOS 26. Runs **each Linux container inside its own lightweight VM**
  (Virtualization.framework), hardware-isolated, sub-second start, OCI images
  from Docker Hub work out of the box.
- So: yes, Apple has first-party containerized delivery now. It's great for the
  **Linux/service** parts of a system.

## The hard limit: no GPU in containers/VMs on macOS

- **No Metal/GPU passthrough.** macOS virtualization (Apple's `container`,
  Docker, Podman, Parallels) goes through Hypervisor.framework, which exposes
  **no virtual GPU**. Full passthrough is *impossible* on Apple Silicon (the host
  needs the GPU for display; there's no secondary device-control interface).
- Therefore **CoreML, the Apple Neural Engine (ANE), MLX, and PyTorch-MPS do not
  accelerate inside a Linux container** — they're macOS-native APIs. In a
  container you get **CPU only**.
- The `apple/container` project confirms this (open discussion: "GPU passthrough
  availability?" → not available).

### Partial workaround (not Apple's container)
Podman + **libkrun** paravirtualizes the GPU by routing **Vulkan** calls out to a
Vulkan→Metal layer on the host. This gives *some* acceleration for Vulkan-capable
workloads (e.g. `llama.cpp`), but it's "far, far less than native," and it's
Podman/libkrun — **not** Apple's `container` (which has no GPU support at all).

## The correct pattern (and the industry has converged on it)

**Run the model natively on the host (Metal), expose an HTTP API, let containers
call it.** This is precisely what **Docker Model Runner** does on macOS: it does
*not* run models in a container — it runs them on the host via Metal
(`vllm-metal` unifies MLX + PyTorch behind vLLM's OpenAI-compatible server on
`localhost:12434`), avoiding VM overhead and the no-GPU limitation.

## What this means for Odysseus

This **confirms and strengthens** our standing decision (see `PORTING_PLAN.md`):
the ML/PDF moat (`fastembed`, `torch`, `diffusers`, `faster-whisper`, …) **stays
a native Python service behind HTTP — never inside the app container.** On macOS
specifically:

- **ML services run natively** on macOS to use the GPU/ANE (torch-MPS / MLX /
  CoreML / `vllm-metal`), exposing OpenAI-compatible or simple JSON HTTP. Odysseus
  already speaks OpenAI-compatible endpoints, so a host-native `vllm-metal` or
  Docker Model Runner can be a drop-in LLM/embedding backend.
- **Everything else can be containerized** — the Racket app/server and the
  non-ML microservices run fine in **Apple `container`** (fast, native, OCI). The
  HTTP boundary is exactly what lets the accelerated ML stay native while the rest
  is containerized.
- **Don't** try to put accelerated ML inside Apple `container`/Docker/Podman on
  Mac — you'll silently fall back to CPU. If you must containerize an inference
  engine on Mac and it speaks Vulkan, Podman+libkrun is the only path to *partial*
  GPU, at a real performance cost.

**Net:** Apple's container is a good answer for the Linux/service tier on Mac, and
a non-answer for accelerated ML. The HTTP-isolated ML moat we already committed to
is the right design on every platform, and the only workable one on macOS.

## Sources
- [Meet Containerization — WWDC25](https://developer.apple.com/videos/play/wwdc2025/346/)
- [Apple container — Wikipedia](https://en.wikipedia.org/wiki/Apple_container)
- [apple/container — "GPU passthrough availability?"](https://github.com/apple/container/discussions/62)
- [Enabling containers to access the GPU on macOS (why passthrough is impossible)](https://www.sinrega.org/2024-03-06-enabling-containers-gpu-macos/)
- [Red Hat — improving AI inference on macOS Podman containers (libkrun Vulkan→Metal)](https://developers.redhat.com/articles/2025/06/05/how-we-improved-ai-inference-macos-podman-containers)
- [Docker Model Runner + vllm-metal on macOS (host-native Metal, not in-container)](https://www.docker.com/blog/docker-model-runner-vllm-metal-macos/)
