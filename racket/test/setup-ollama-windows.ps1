# racket/test/setup-ollama-windows.ps1 - one-shot ollama setup for the agent.
#
# Installs ollama (>= 0.3.0 is required for OpenAI tool_calls), makes sure the
# service is up on 127.0.0.1:11434, pulls a model, and smoke-tests that the
# model actually returns a tool_call. Safe to re-run (idempotent).
#
#   powershell -ExecutionPolicy Bypass -File test\setup-ollama-windows.ps1
#   powershell -ExecutionPolicy Bypass -File test\setup-ollama-windows.ps1 -Model qwen2.5:3b
#
# Model guidance (see PERFORMANCE.md): qwen2.5:7b is the reliable default
# (~5-6 GB RAM/VRAM). On <8 GB hosts use -Model qwen2.5:3b (simple tasks only).
#
# NOTE: this file is deliberately ASCII-only. Windows PowerShell 5.1 reads a
# .ps1 with no BOM as the system ANSI codepage, so non-ASCII bytes (em dashes,
# arrows) can corrupt parsing. Keep it ASCII.
param(
  [string]$Model = "qwen2.5:7b"
)
$ErrorActionPreference = 'Stop'
function Info($m){ Write-Host "[i] $m" }
function Ok($m){ Write-Host "[ok] $m" }
function Die($m){ Write-Host "[X] $m"; exit 1 }

# ---- 1. install ollama if missing -------------------------------------------
$ollama = Get-Command ollama -ErrorAction SilentlyContinue
if (-not $ollama) {
  Info "ollama not found - installing..."
  if (Get-Command winget -ErrorAction SilentlyContinue) {
    winget install --id Ollama.Ollama -e --accept-source-agreements --accept-package-agreements
  } else {
    Info "winget unavailable - downloading the official installer..."
    $exe = Join-Path $env:TEMP "OllamaSetup.exe"
    Invoke-WebRequest -Uri "https://ollama.com/download/OllamaSetup.exe" -OutFile $exe
    Info "launching installer (click through it, then re-run this script)..."
    Start-Process -Wait -FilePath $exe
  }
  # winget/installer drops ollama here but it may not be on THIS shell's PATH yet
  $cand = Join-Path $env:LOCALAPPDATA "Programs\Ollama"
  if (Test-Path (Join-Path $cand "ollama.exe")) { $env:Path = "$cand;$env:Path" }
  if (-not (Get-Command ollama -ErrorAction SilentlyContinue)) {
    Die "ollama still not on PATH - open a NEW terminal and re-run this script."
  }
}
Ok ("ollama present: " + ((& ollama --version 2>&1) -join ' '))

# ---- 2. make sure the service is up -----------------------------------------
function Ollama-Up { try { Invoke-WebRequest -UseBasicParsing -TimeoutSec 2 "http://127.0.0.1:11434/api/version" | Out-Null; $true } catch { $false } }
if (-not (Ollama-Up)) {
  Info "starting ollama service..."
  Start-Process ollama -ArgumentList "serve" -WindowStyle Hidden
  for ($i=0; $i -lt 30; $i++) { if (Ollama-Up) { break }; Start-Sleep -Milliseconds 500 }
}
if (-not (Ollama-Up)) { Die "ollama service did not come up on :11434 (is the Ollama app running in the tray?)" }
$ver = (Invoke-WebRequest -UseBasicParsing "http://127.0.0.1:11434/api/version").Content
Ok "service up on 127.0.0.1:11434 - $ver"
# version >= 0.3.0 gate (older builds silently ignore the tools field)
$m = [regex]::Match($ver, '(\d+)\.(\d+)\.(\d+)')
if ($m.Success) {
  $maj = [int]$m.Groups[1].Value; $min = [int]$m.Groups[2].Value
  if ($maj -eq 0 -and $min -lt 3) { Die "ollama $($m.Value) is too old for tool_calls - need >= 0.3.0; update from ollama.com" }
}

# ---- 3. pull the model ------------------------------------------------------
$tags = (Invoke-WebRequest -UseBasicParsing "http://127.0.0.1:11434/api/tags").Content
if ($tags -like "*$Model*") { Ok "model '$Model' already pulled" }
else { Info "pulling '$Model' (one-time download)..."; & ollama pull $Model; if ($LASTEXITCODE -ne 0) { Die "pull failed" }; Ok "pulled '$Model'" }

# ---- 4. smoke-test a real tool_call -----------------------------------------
# Body is a here-string (literal JSON), NOT a PowerShell hashtable: a hashtable
# key named `function` collides with the PS keyword and breaks the parser.
Info "smoke-testing tool_calls with '$Model'..."
$body = @"
{"model":"$Model","tool_choice":"auto","temperature":0,
 "messages":[{"role":"user","content":"List the files in the current directory using the ls tool."}],
 "tools":[{"type":"function","function":{"name":"ls","description":"List a directory",
   "parameters":{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}}}]}
"@
$resp = Invoke-RestMethod -Method Post -Uri "http://127.0.0.1:11434/v1/chat/completions" -ContentType "application/json" -Body $body
if ($resp.choices[0].message.tool_calls) {
  Ok ("tool_calls work - model returned: " + $resp.choices[0].message.tool_calls[0].function.name)
} else {
  Write-Host "[warn] no tool_call this time (small models are nondeterministic; the agent sends temperature 0 to mitigate)."
}

Write-Host ""
Write-Host "============================================================"
Write-Host " ollama ready. Next:"
Write-Host "   `$env:LLM_MODEL_OLLAMA='$Model'; powershell -File test\integration.ps1   # live stage"
Write-Host "   # or drive the agent directly:"
Write-Host "   `$env:LLM_ENDPOINT='http://127.0.0.1:11434/v1/chat/completions'; `$env:LLM_MODEL='$Model'"
Write-Host "   racket cli/odysseus-agent.rkt 'add a note: buy milk' --owner me --tools manage_notes"
Write-Host "============================================================"
