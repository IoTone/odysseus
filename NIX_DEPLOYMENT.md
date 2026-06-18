# Nix packaging & wide-deployment plan

Goal: deploy the Racket port (CLIs + agent + server) across **macOS**,
**Windows**, **MediaTek Genio 720**, **Ubuntu (x86_64)**, and **standalone
NixOS** with as few hand-written setup scripts as possible, and "hammer
portability" **once in CI** rather than on every machine.

The thesis: **Nix is the deployment substrate for every target that can run it,
and that's four of the five.** Build once per CPU architecture in CI, push the
result to a binary cache, and every device installs a *prebuilt* closure — no
compiler, no `raco pkg install`, no PATH munging, no per-distro dependency
script. Windows is the one genuine exception; we keep its existing native path
and contain the blast radius.

The repo has a working multi-system `flake.nix` (4 systems, wrapper-based
install, test suite in `checkPhase`). This plan extends it: the §4a–4c deltas
(derived build list, NixOS module, OCI image) are **landed and validated
locally**; the cache/CI/remote-builder pieces (§2–3) and §4d are the
infra-side work still to do.

---

## 1. The portability matrix (be honest about Nix's reach)

| Target | Nix `system` | Nix-native? | How it gets the software |
|---|---|---|---|
| Ubuntu (this machine) | `x86_64-linux` | ✅ | `nix profile install` from cache |
| Standalone NixOS | `x86_64-linux` / `aarch64-linux` | ✅ | NixOS module (declarative) |
| macOS (Apple silicon) | `aarch64-darwin` | ✅ | `nix profile install` (+ optional nix-darwin) |
| macOS (Intel) | `x86_64-darwin` | ✅ | same |
| **MTK Genio 720** | `aarch64-linux` | ✅ *if* Nix installs on its distro | `nix profile install`, or `nix copy` a closure, or an OCI image |
| **Windows** | — | ❌ **not native** | WSL2 (= `x86_64-linux`), *or* the existing native-Racket installer |

**The whole game** is that rows 1–5 are the *same* Nix workflow differing only
by `system` string. Windows is the outlier and is addressed in §6.

The Genio 720 is a standard `aarch64` SoC (Cortex-A78/A55) running Linux — to
Nix it's just another `aarch64-linux` machine. Its NPU/APU is irrelevant to us:
the ML moat stays Python-on-a-real-host (see `apple-ml-containers.md` /
PORTING_PLAN), and the Genio runs only the agent + tools (+ optionally a small
CPU LLM, see PERFORMANCE.md).

---

## 2. The linchpin: a binary cache (build once, install everywhere)

This is what removes the setup scripts. Without a cache, each device compiles
Racket bytecode itself (slow on a Genio, impossible-ish on a phone-class board);
with one, each device downloads a finished closure.

- **CI builds** `packages.<system>.odysseus` for `x86_64-linux`,
  `aarch64-linux`, `x86_64-darwin`, `aarch64-darwin` and **pushes to a cache**:
  - **Cachix** (hosted, simplest), or **attic** (self-hosted, you own it).
- **Devices trust the cache** via `nixConfig` in the flake so no per-device
  config is needed:

  ```nix
  # flake.nix
  nixConfig = {
    extra-substituters = [ "https://odysseus.cachix.org" ];
    extra-trusted-public-keys = [ "odysseus.cachix.org-1:<pubkey>" ];
  };
  ```
- Then on **any** Nix target, the entire install is one line, no build:

  ```bash
  nix profile install github:iotone/odysseus#odysseus   # pulls prebuilt closure
  odysseus-agent "add a note: buy milk" --owner me --tools manage_notes
  ```

That one command replaces: install-racket.sh, `raco pkg install`, dependency
apt/brew lines, and PATH setup — on Ubuntu, macOS, NixOS, and the Genio alike.

---

## 3. Cross-arch builds (the gaming laptop is x86_64; Genio + Apple are arm64)

Racket CS does not cross-compile cleanly, so **don't cross-compile — build
natively per arch** and cache the result. Three ways, pick per budget:

1. **CI with native runners (recommended).** GitHub Actions matrix:
   `ubuntu-latest` (x86_64-linux), `ubuntu-24.04-arm` (aarch64-linux),
   `macos-14` (aarch64-darwin), `macos-13` (x86_64-darwin). Each runs
   `nix build .#odysseus` + `nix flake check` and `cachix push`. Result: all
   four closures in the cache on every commit.
2. **A remote aarch64-linux builder** (a cheap arm cloud box, or the Genio
   itself registered as a `nix.buildMachines` entry) — the laptop offloads
   aarch64 builds to it. Good when you don't want CI for arm.
3. **binfmt/QEMU emulation** (`boot.binfmt.emulatedSystems` on a NixOS builder,
   or `nix build --system aarch64-linux` under qemu) — slowest, zero extra
   hardware, fine for occasional arm builds.

> The Genio can also just **build for itself** once (`nix build` on-device) and
> push to the cache so the next N Genios pull it — turn one device into the
> arm builder.

---

## 4. Flake delta

§4a–4c are **landed** in `flake.nix` (validated locally: package builds with
the suite hermetic in the sandbox, the NixOS module evaluates inside a real
`nixosSystem`, the OCI image streams). §4d is still proposed. The current flake
produces wrapper-based CLIs plus:

### 4a. Derive the build list (kill the drift) — ✅ landed

`buildPhase` used to hardcode the `raco make` file list while `entrypoints` was
a separate variable — they drifted (a review finding). Now one is derived from
the other (`makeList` from `entrypoints`), so adding a CLI updates both the
build and the wrappers from a single list.

> Hermeticity note found while validating this: the Nix build sandbox has **no
> network**, which surfaced a non-hermetic test (a webhook assertion that
> resolved a DNS name). Fixed to use a public IP literal. This is the §7 payoff
> in miniature — the sandbox *is* a portability check.

### 4b. NixOS module (declarative deploy) — ✅ landed

```nix
# nixosModules.odysseus
{ config, lib, pkgs, ... }:
let cfg = config.services.odysseus; in {
  options.services.odysseus.enable = lib.mkEnableOption "Odysseus agent/server";
  options.services.odysseus.port = lib.mkOption { type = lib.types.port; default = 8099; };
  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ self.packages.${pkgs.system}.odysseus ];
    systemd.services.odysseus-server = {
      wantedBy = [ "multi-user.target" ];
      serviceConfig.ExecStart =
        "${self.packages.${pkgs.system}.odysseus}/bin/odysseus-server --port ${toString cfg.port}";
      serviceConfig.DynamicUser = true;
    };
    # ollama is in nixpkgs — no setup script needed on Nix hosts:
    services.ollama = { enable = true; loadModels = [ "qwen2.5:7b" ]; };
  };
}
```

A NixOS device (standalone box *or* a Genio running NixOS) then needs only:

```nix
{ services.odysseus.enable = true; }
```

…and `nixos-rebuild switch` installs the agent, wires a systemd service, **and
sets up ollama with the model preloaded** — the entire runtime, declaratively,
zero imperative scripts.

### 4c. OCI image (container-capable devices / k8s / Genio on Docker) — ✅ landed

```nix
packages.<system>.container = pkgs.dockerTools.streamLayeredImage {
  name = "odysseus";
  contents = [ self.packages.<system>.odysseus ];
  config.Entrypoint = [ "/bin/odysseus-agent" ];
};
# nix build .#container | docker load   (arch-matched image, reproducible)
```

### 4d. integration.sh as a flake check (portability, once) — ✅ landed

```nix
checks.<system>.integration = pkgs.runCommand "odysseus-integration"
  { nativeBuildInputs = [ pkgs.racket pkgs.python3 pkgs.curl pkgs.bash pkgs.coreutils ]; }
  ''
    export HOME=$TMPDIR
    cp -r ${./racket} racket && chmod -R u+w racket
    cd racket
    export PLTCOLLECTS="$PWD/pkgs:"
    bash test/integration.sh        # the SAME script the developer runs
    touch $out
  '';
```

The check runs the developer's `test/integration.sh` verbatim against the
racket-only source. In the sandbox: compile (1) + suite (2) + mock end-to-end
(4) all run — loopback is up, the DB/skills land in `$TMPDIR`, the mock LLM
needs no network. Fidelity (3) self-skips when the `ci/` + Python tree isn't in
the checkout; live ollama (5) self-skips with nothing on `:11434`. Validated
locally: `nix build .#checks.x86_64-linux.integration -L` → `INTEGRATION OK`.

Now `nix flake check` on each CI arch runs the **same** end-to-end the
developer runs, so "does it work on aarch64-linux / aarch64-darwin?" is answered
by CI, not by shipping to a Genio and hoping. (The fidelity drift-gate against
live Python is the complementary full-checkout lane — `bash
racket/test/integration.sh` from the repo root, where `ci/` and `python3` exist.)

---

## 5. Per-target deploy recipes

- **Ubuntu (x86_64-linux):** `nix profile install github:iotone/odysseus#odysseus`.
  (One-time: install Nix via the Determinate Systems installer.)
- **Standalone NixOS:** add `nixosModules.odysseus` to the system flake,
  `services.odysseus.enable = true;`, `nixos-rebuild switch`.
- **macOS (arm64/x86_64):** install Nix, then `nix profile install …#odysseus`.
  For fleet management use **nix-darwin** with the same module pattern.
- **MTK Genio 720 (aarch64-linux):** ranked options —
  1. **Nix on-device + cache:** install Nix (single-user is fine on a
     non-NixOS Genio image), `nix profile install …#odysseus` → pulls the
     cached aarch64 closure. Cleanest.
  2. **`nix copy` (device needs only a Nix store, not a daemon/network):**
     from a builder/CI: `nix copy --to ssh://genio github:iotone/odysseus#odysseus`.
     Good for an offline/locked-down board.
  3. **OCI image** (§4c) if the Genio runs containers.
  4. **Escape hatch if the Genio cannot run Nix at all** (constrained Yocto):
     `raco distribute` a relocatable bundle on an aarch64 builder and `scp` it.
     This drops Nix's reproducibility guarantee — last resort, documented as
     such.
- **Windows:** see §6.

---

## 6. Windows — the one target outside Nix

Nix has no native Windows support. Two honest paths:

1. **WSL2 + Nix (recommended for parity).** Inside WSL2 the system is
   `x86_64-linux`, so it's *identical* to the Ubuntu path — same
   `nix profile install`, same cache, same closure. The agent reaches Windows
   services over `localhost`. This makes Windows "just another Linux target"
   for everything except native-Win32 GUI work.
2. **Native Windows (no WSL).** Keep the existing, already-working path:
   `validate-windows.bat` (official Racket installer + `raco exe` standalone)
   and `setup-ollama-windows.ps1`. This is the only place we still maintain
   setup scripts — and it's bounded to one OS.

Recommendation: **default Windows deployments to WSL2** (one workflow to
maintain); keep the native installer path for hosts that can't use WSL.

---

## 7. How this collapses portability testing

Without Nix: validate on every (OS × distro × arch) by hand. With this plan:

| Lane | Covers | Mechanism |
|---|---|---|
| **Nix CI matrix** | Ubuntu, NixOS, macOS×2, Genio (all 4 Nix `system`s) | `nix flake check` per native runner → builds + suite + integration |
| **Windows CI lane** | native Windows | run `validate-windows.bat` + `integration.ps1` on a `windows-latest` runner |

Two CI lanes validate **all five targets**. A green matrix means every Nix
target is byte-for-byte reproducible and tested; the Genio gets exactly the
closure CI tested, not a re-compile. The manual `test-plan-manual.html` /
`VALIDATION.md` runbooks remain for spot-checks, but are no longer the primary
gate.

---

## 8. Rollout order (suggested)

1. Stand up a cache (Cachix free tier or attic) + wire `nixConfig`.
2. Add the CI matrix (x86_64-linux first — already builds today — then
   aarch64-linux, then the two darwins) pushing to the cache.
3. Add the NixOS module + `services.ollama`; convert this Ubuntu box and the
   NixOS box to `nix profile install` / the module. Delete the bespoke
   install steps from their runbooks.
4. Bring up the Genio via on-device `nix profile install` from the cache;
   fall back to `nix copy` if its image can't host Nix.
5. Decide Windows: WSL2 for new deployments; keep the `.bat`/`.ps1` for native.
6. Move `integration.sh` into `nix flake check` so portability is a CI gate.

**Net effect:** one `flake.nix` + one cache + two CI lanes replace the
per-distro install scripts and most manual cross-platform testing. The only
hand-maintained setup scripts left are the two Windows ones.
