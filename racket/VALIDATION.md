# Cross-platform validation runbook (macOS & Windows)

A copy-paste script to validate the Racket port on a fresh machine. Linux is
already verified in CI; this is for **you** to run on **macOS** and **Windows**.
Each step shows the command and the **expected** output — if something differs,
note it and report back (a screenshot or the terminal text is perfect).

> Companion to the interactive `test-plan-manual.html` (open it in a browser for
> a checkbox version). This file is the linear "just run these" path.
>
> **The single fullest check** runs compile → suite → real-agent-loop
> end-to-end (a scripted mock LLM, no model needed) → optional live ollama:
> - macOS / Linux: `racket/test/integration.sh` (also runs Python fidelity)
> - Windows: `powershell -ExecutionPolicy Bypass -File racket\test\integration.ps1`
>
> The per-OS steps below are the breakdown + the packaging (`raco exe`) check
> the integration scripts don't cover. `validate-windows.bat` remains the quick
> compile+suite+exe smoke; `integration.ps1` is the fuller end-to-end.

Pinned Racket version: **9.2 (CS)**. Run all commands from the **repo root**
unless a step says `cd racket`.

---

## macOS

> **Directories:** steps 1–2 run from the **repo root**. Step 3 does `cd racket`,
> and steps 4–6 stay in `racket/`.

### 1. Install Racket  *(from repo root)*
Homebrew is the tried-and-true path on macOS (Intel and Apple Silicon both work):

```bash
brew install minimal-racket          # gives racket + raco on PATH
racket --version                     # expect: Welcome to Racket v9.2 [cs].
```

> If `raco exe` in step 6 fails, install the **official** build instead and
> re-test: `brew install --cask racket` (or the `.dmg` from
> <https://download.racket-lang.org/>). Please report which one you used.

### 2. Install dependencies (catalog libs + our local packages)
```bash
# web-server/db/rackunit are bundled in full Racket — install only if missing
# (the --cask/official build bundles them; minimal-racket does not):
racket -e "(require web-server/servlet-env db rackunit)" 2>/dev/null || raco pkg install --auto web-server-lib db-lib
raco pkg install --link racket/pkgs/cli-kit racket/pkgs/db-kit racket/pkgs/web-kit
```
Expect: `raco setup` output ending without errors.

### 3. Build (byte-compile)  *(cd into racket/ — stay here for steps 4–6)*
```bash
cd racket
raco make config.rkt cli/*.rkt domain/*.rkt server/*.rkt test/*.rkt
echo "build: $?"
```
Expect: no errors, `build: 0`.

### 4. Automated test suite (the main signal)  *(in racket/)*
```bash
racket test/run-tests.rkt
```
Expect: `24 success(es) 0 failure(s) 0 error(s) 24 test(s) run`.

### 5. Smoke the CLIs and server
```bash
racket cli/odysseus-logs.rkt --version           # -> odysseus-logs 0.1.0
ODYSSEUS_DATA_DIR=$(mktemp -d) racket cli/odysseus-preset.rkt list   # -> []

racket test/seed-db.rkt                          # create app schema + sample rows
racket server/main.rkt --port 8099 &             # start server
sleep 2
curl -s localhost:8099/health; echo              # -> {"status":"ok",...}
curl -s localhost:8099/api/notes; echo           # -> {"notes":[...]} (seeded; web shape)
kill %1                                           # stop server
```

### 6. Packaging — standalone binary (the portability check)
```bash
mkdir -p dist
raco exe -o dist/odysseus-logs cli/odysseus-logs.rkt
./dist/odysseus-logs --version                   # -> odysseus-logs 0.1.0 (no crash)
```
Expect: builds and runs. **A crash/segfault here is the key thing to report**
(it's what happens with Homebrew on *Linux*; we want to know if macOS differs).

---

## Windows (PowerShell)

> Use **PowerShell** (not cmd). There is no native ARM build for 9.2 — on
> Windows-on-ARM, install the x86_64 build (runs under emulation).
>
> **Directories:** steps 1–2 run from the **repo root**. Step 3 does `cd racket`,
> and steps 4–6 stay in `racket\`.
>
> **Shortcut:** after step 1 (Racket installed + on PATH), just run
> `racket\validate-windows.bat` — it does steps 2–4 + 6 (deps → build → suite →
> `raco exe` + run) and stops at the first failure. Steps below are the manual
> equivalent.

### 1. Install Racket (official build)  *(from repo root)*
```powershell
$ver = "9.2"
$url = "https://download.racket-lang.org/installers/$ver/racket-$ver-x86_64-win32-cs.exe"
Invoke-WebRequest -Uri $url -OutFile "$env:TEMP\racket-install.exe"
# Silent install to C:\racket (/S silent, /D dir — NSIS: /D must be last, unquoted)
Start-Process -Wait -FilePath "$env:TEMP\racket-install.exe" -ArgumentList "/S","/D=C:\racket"
$env:Path = "C:\racket;" + $env:Path     # this session; add permanently in System env too
racket --version                          # expect: Welcome to Racket v9.2 [cs].
```
(Or just double-click the downloaded installer and use the GUI, then add
`C:\racket` to PATH.)

### 2. Install dependencies
```powershell
# Official Racket already bundles web-server/db/rackunit — install ONLY if missing
# (installing a bundled package errors with "installed in a wider scope"):
racket -e "(require web-server/servlet-env db rackunit)" 2>$null
if ($LASTEXITCODE -ne 0) { raco pkg install --auto --batch web-server-lib db-lib }
raco pkg install --link --batch racket\pkgs\cli-kit racket\pkgs\db-kit racket\pkgs\web-kit
```
(Or just run `racket\validate-windows.bat`, which handles this.)

### 3. Build (explicit file list — PowerShell does NOT expand `*.rkt` for raco)  *(cd into racket\)*
```powershell
cd racket
# (the agent CLI + test suite transitively compile domain/{tasks,integrations,
#  documents,settings-tool,util}.rkt and domain/{tools,agent}/*.rkt)
raco make config.rkt cli/odysseus-logs.rkt cli/odysseus-preset.rkt cli/odysseus-signature.rkt cli/odysseus-notes.rkt cli/odysseus-sessions.rkt cli/odysseus-tasks.rkt cli/odysseus-research.rkt cli/odysseus-mcp.rkt cli/odysseus-calendar.rkt cli/odysseus-agent.rkt domain/notes.rkt domain/sessions.rkt server/main.rkt server/proxy.rkt test/run-tests.rkt test/seed-db.rkt
racket cli/odysseus-agent.rkt --version            # -> odysseus-agent 0.1.0
```
Expect: no errors.

### 4. Automated test suite (the main signal)  *(in racket\)*
```powershell
racket test/run-tests.rkt
```
Expect: `24 success(es) 0 failure(s) 0 error(s) 24 test(s) run`.

### 4b. End-to-end through the real agent loop  *(in racket\)*
The fuller check — drives loop → tool dispatch → on-disk SQLite via a scripted
mock LLM (no model), then an optional live-ollama round-trip if `:11434` is up:
```powershell
powershell -ExecutionPolicy Bypass -File test\integration.ps1
```
Expect: the `[ok]` lines for every `manage_*` scenario and
`INTEGRATION OK (Windows)`. The mock-LLM stage needs **no model** — it always
runs. The live-ollama stage auto-skips unless ollama is up.

To exercise the live stage, set up ollama first (installs it, starts the
service, pulls a model, smoke-tests tool_calls):
```powershell
powershell -ExecutionPolicy Bypass -File test\setup-ollama-windows.ps1
# smaller host: ... setup-ollama-windows.ps1 -Model qwen2.5:3b   (see PERFORMANCE.md)
```
Then `$env:LLM_MODEL_OLLAMA='qwen2.5:7b'` before `integration.ps1`. (The live
stage may print `[warn]` on a small model — model quality, not a wiring bug.)

### 5. Smoke the CLIs and server
```powershell
racket cli/odysseus-logs.rkt --version            # -> odysseus-logs 0.1.0
$env:ODYSSEUS_DATA_DIR = (New-Item -ItemType Directory -Path "$env:TEMP\odyd" -Force).FullName
racket cli/odysseus-preset.rkt list               # -> []

racket test/seed-db.rkt                                      # create schema + sample rows
Start-Process racket -ArgumentList "server/main.rkt","--port","8099"
Start-Sleep 2
(Invoke-WebRequest http://localhost:8099/health).Content    # -> {"status":"ok",...}
(Invoke-WebRequest http://localhost:8099/api/notes).Content # -> {"notes":[...]} (seeded)
# stop it: Get-Process racket | Stop-Process
```

### 6. Packaging — standalone .exe
```powershell
New-Item -ItemType Directory -Force -Path dist | Out-Null
raco exe -o dist/odysseus-logs.exe cli/odysseus-logs.rkt
.\dist\odysseus-logs.exe --version                # -> odysseus-logs 0.1.0
```

---

## Collecting results (Windows)

Run both, capturing each to a log file, then send the two `.txt` files (each
starts with a host header that identifies the machine):

```powershell
cd racket
# 1) quick smoke (compile + 24-test suite + standalone .exe)
cmd /c validate-windows.bat 2>&1 | Tee-Object -FilePath "$env:USERPROFILE\odyssey-validate.txt"

# 2) full end-to-end (real agent loop -> tool dispatch -> on-disk SQLite via a
#    mock LLM; live-ollama stage auto-skips if :11434 isn't up)
powershell -ExecutionPolicy Bypass -File test\integration.ps1 2>&1 |
  Tee-Object -FilePath "$env:USERPROFILE\odyssey-integration.txt"
```

`Tee-Object` shows the run live *and* writes the file. Both end with a clear
banner: `ALL GREEN` / `INTEGRATION OK (Windows)` on success, or a `[X]` line at
the first failure. Send both files (or just paste their contents) — the host
header + `[ok]`/`[X]` lines are all I need.

## What to report back

For each OS, the things that matter most:

| # | Check | Pass looks like |
|---|---|---|
| A | `racket --version` | `v9.2 [cs]` |
| B | Build (step 3) | no errors |
| C | Test suite (step 4) | `24 success(es) 0 failure(s)` |
| D | End-to-end (step 4b / integration.ps1) | every `[ok]`, `INTEGRATION OK (Windows)` |
| E | `raco exe` binary runs (step 6) | prints version, **no crash** |

If anything fails, copy the terminal output (especially C and D) and send it
over — that tells us exactly what to fix for that platform.
