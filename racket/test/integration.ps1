# racket/test/integration.ps1 — Windows end-to-end check for the Racket port.
# PowerShell sibling of test/integration.sh: compile -> suite -> mock-LLM
# end-to-end (the REAL agent loop -> tool dispatch -> on-disk SQLite, no model)
# -> optional live ollama. Fidelity diffs are Linux-CI's job (need the app
# venv) and are intentionally not run here.
#
#   Run from the racket\ dir:  powershell -ExecutionPolicy Bypass -File test\integration.ps1
#   Require the live stage:     $env:OLLAMA=1; powershell -File test\integration.ps1
$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location (Split-Path -Parent $ScriptDir)              # racket\ dir
if (-not (Get-Command racket -ErrorAction SilentlyContinue)) { Write-Host "[X] racket not on PATH"; exit 1 }

function Pass($m){ Write-Host "  [ok] $m" }
function Fail($m){ Write-Host "  [X] $m"; if ($script:Mock) { Stop-Process -Id $script:Mock.Id -Force -ErrorAction SilentlyContinue }; exit 1 }

# PowerShell does NOT expand *.rkt for raco; explicit list (transitive requires
# pull in the rest of domain/).
$entry = @(
  'config.rkt','cli/odysseus-agent.rkt','domain/notes.rkt','domain/tasks.rkt',
  'domain/integrations.rkt','domain/documents.rkt','domain/settings-tool.rkt',
  'domain/skills.rkt','domain/calendar-tool.rkt','domain/nl-datetime.rkt',
  'domain/tools/result.rkt','test/mock-llm.rkt','test/run-tests.rkt','test/seed-db.rkt')

Write-Host "== 1/4  compile =="
& raco make @entry 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { Fail "compile failed" } else { Pass "raco make clean" }

Write-Host "== 2/4  unit suite =="
$suite = & racket test/run-tests.rkt 2>&1 | Out-String
if ($suite -match '0 failure\(s\) 0 error\(s\)') { Pass ($suite.Trim() -split "`n")[-1] } else { Write-Host $suite; Fail "suite not green" }

# ---- end-to-end scaffolding -------------------------------------------------
$Work = Join-Path $env:TEMP ("odyintg_" + [guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Force -Path (Join-Path $Work 'data') | Out-Null
$env:DATABASE_URL  = "sqlite:///" + ($Work -replace '\\','/') + "/app.db"
$env:ODYSSEUS_DATA_DIR = Join-Path $Work 'data'
& racket test/seed-db.rkt 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { Fail "seed-db failed" }

$Port = 8911
$CallFile = Join-Path $Work 'call.json'
$env:MOCK_PORT = "$Port"; $env:MOCK_CALL_FILE = $CallFile

function Agent-Run($tool, $argsJson) {
  # call file = {"name": tool, "arguments": "<args-json-as-string>"}
  # WriteAllText → UTF-8 with NO BOM (Set-Content -Encoding utf8 adds a BOM on
  # PowerShell 5.1, which would break the mock's string->jsexpr).
  $json = @{ name = $tool; arguments = $argsJson } | ConvertTo-Json -Compress
  [System.IO.File]::WriteAllText($CallFile, $json, (New-Object System.Text.UTF8Encoding $false))
  $env:LLM_ENDPOINT = "http://127.0.0.1:$Port/v1/chat/completions"; $env:LLM_MODEL = "mock"
  (& racket cli/odysseus-agent.rkt "integration: $tool" --owner alice --pretty --max-rounds 4 2>$null) | Out-String
}
function Expect($out, $needle, $label) {
  if ($out -like "*$needle*") { Pass $label } else { Write-Host ($out.Substring(0,[Math]::Min(900,$out.Length))); Fail $label }
}

Write-Host "== 3/4  mock end-to-end (real loop + real DB) =="
$script:Mock = Start-Process racket -ArgumentList 'test/mock-llm.rkt' -PassThru -WindowStyle Hidden -RedirectStandardOutput (Join-Path $Work 'mock.log') -RedirectStandardError (Join-Path $Work 'mock.err')
for ($i=0; $i -lt 50; $i++) {
  try { Invoke-WebRequest -UseBasicParsing -TimeoutSec 1 -Method Post -Body '{}' "http://127.0.0.1:$Port/v1/chat/completions" | Out-Null; break } catch { Start-Sleep -Milliseconds 100 }
}

Expect (Agent-Run 'manage_notes'    '{"action":"add","title":"IntgNote","checklist_items":[{"text":"x"}]}') 'Note created'   'manage_notes add'
Expect (Agent-Run 'manage_tasks'     '{"action":"create","prompt":"summarize","schedule":"daily","scheduled_time":"07:00"}') 'Created task' 'manage_tasks create'
Expect (Agent-Run 'manage_calendar'  '{"action":"create_event","summary":"IntgEvt","dtstart":"2026-06-20T09:00:00","reminder_minutes":30}') 'Created event' 'manage_calendar create_event'
Expect (Agent-Run 'manage_endpoints' '{"action":"add","name":"IntgEp","base_url":"https://api.example/v1"}') 'Added endpoint' 'manage_endpoints add'
Expect (Agent-Run 'manage_skills'    '{"action":"add","name":"intg-skill","description":"d","procedure":["step one"]}') 'Created skill' 'manage_skills add'
Expect (Agent-Run 'manage_settings'  '{"action":"set","key":"search engine","value":"brave"}') 'Set search_provider = brave' 'manage_settings set'
Expect (Agent-Run 'manage_documents' '{"action":"list"}') 'Meeting notes' 'manage_documents list (seeded, owner-scoped)'
Expect (Agent-Run 'manage_notes'     '{"action":"list"}') 'IntgNote' 'manage_notes persisted to disk (cross-process)'
Expect (Agent-Run 'manage_notes'     '{"action":"list"}') 'Reminder: IntgEvt' 'calendar reminder note persisted'

Stop-Process -Id $script:Mock.Id -Force -ErrorAction SilentlyContinue; $script:Mock = $null

Write-Host "== 4/4  live ollama (real model) =="
$ollamaUp = $false
try { Invoke-WebRequest -UseBasicParsing -TimeoutSec 2 "http://127.0.0.1:11434/api/version" | Out-Null; $ollamaUp = $true } catch {}
if ($ollamaUp) {
  $model = if ($env:LLM_MODEL_OLLAMA) { $env:LLM_MODEL_OLLAMA } else { 'qwen2.5:7b' }
  $tags = (Invoke-WebRequest -UseBasicParsing -TimeoutSec 2 "http://127.0.0.1:11434/api/tags").Content
  if ($tags -like "*$model*") {
    $env:LLM_ENDPOINT = "http://127.0.0.1:11434/v1/chat/completions"; $env:LLM_MODEL = $model
    $res = (& racket cli/odysseus-agent.rkt "Use the manage_notes tool to create a checklist note titled 'Live Intg' with one item 'ship it'." --owner alice --pretty --max-rounds 6 2>$null) | Out-String
    if ($res -match '"tool":"manage_') {
      Pass "live model issued a real tool call, executed end-to-end ($model)"
      if ($res -like '*Live Intg*') { Pass "manage_notes created the note via live model" }
      else { Write-Host "  [note] model didn't land the exact note (tool selection varies at 20 tools); wiring verified" }
    } else {
      Write-Host ($res.Substring(0,[Math]::Min(900,$res.Length)))
      Write-Host "  [warn] live model issued no tool call — model-quality, not wiring (try LLM_MODEL_OLLAMA=qwen2.5:14b)"
      if ($env:OLLAMA -eq '1') { Fail "OLLAMA=1 but live model issued no tool call" }
    }
  } else { Write-Host "  [skip] ollama up but model '$model' not pulled"; if ($env:OLLAMA -eq '1') { Fail "OLLAMA=1 but model missing" } }
} else { Write-Host "  [skip] no ollama on :11434"; if ($env:OLLAMA -eq '1') { Fail "OLLAMA=1 but :11434 unreachable" } }

Remove-Item -Recurse -Force $Work -ErrorAction SilentlyContinue
Write-Host ""
Write-Host "============================================================"
Write-Host " INTEGRATION OK (Windows) — compile, suite, mock end-to-end"
Write-Host "============================================================"
