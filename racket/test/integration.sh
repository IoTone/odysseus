#!/usr/bin/env bash
# racket/test/integration.sh — the "mega" end-to-end check for the Racket port.
#
# Layers, fastest→fullest (each stage gates on the previous):
#   1. compile        raco make every entrypoint
#   2. unit suite     test/run-tests.rkt (rackunit, in-memory)
#   3. fidelity       schema + converter byte-identity vs Python   [skipped w/o python3]
#   4. mock end-to-end   the REAL agent loop (loop→HTTP llm adapter→tool-call
#                        protocol→exec dispatch→on-disk SQLite/skills) driven by
#                        a scripted mock LLM — every DB tool, with persistence
#                        re-checked in a separate process. No ollama needed.
#   5. live ollama    a couple of real prompts                     [skipped unless :11434 up]
#
# Usage:  racket/test/integration.sh            # stages 1-4 (+5 if ollama up)
#         OLLAMA=1 racket/test/integration.sh   # require stage 5 (fail if no ollama)
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"          # racket/ dir
export PATH="$HOME/racket/bin:$PATH"
command -v racket >/dev/null || { echo "[X] racket not on PATH"; exit 1; }

pass(){ echo "  [ok] $*"; }
fail(){ echo "  [X] $*"; exit 1; }
RACO_FILES="config.rkt cli/odysseus-agent.rkt domain/notes.rkt domain/tasks.rkt \
  domain/integrations.rkt domain/documents.rkt domain/settings-tool.rkt domain/skills.rkt \
  domain/calendar-tool.rkt domain/nl-datetime.rkt domain/tools/result.rkt test/mock-llm.rkt \
  test/run-tests.rkt test/seed-db.rkt"

echo "== 1/5  compile =="
raco make $RACO_FILES >/dev/null 2>&1 && pass "raco make clean" || fail "compile failed"

echo "== 2/5  unit suite =="
out=$(racket test/run-tests.rkt 2>&1) || { echo "$out"; fail "suite failed"; }
echo "$out" | grep -q " 0 failure(s) 0 error(s)" && pass "$(echo "$out" | tail -1)" || { echo "$out"; fail "suite not green"; }

echo "== 3/5  fidelity (schema + converter vs Python) =="
# Prefer the app venv (the converter check imports src.agent_tools → fastapi…)
[ -x "$ROOT/../.venv/bin/python" ] && export PATH="$ROOT/../.venv/bin:$PATH"
if command -v python3 >/dev/null && python3 -c 'import ast,json' 2>/dev/null; then
  ../ci/fidelity-tools.sh >/dev/null 2>&1 && pass "schemas byte-identical (schema-only, no venv needed)" || fail "schema fidelity"
  if (cd "$ROOT/.." && python3 -c 'import src.agent_tools') >/dev/null 2>&1; then   # importable from repo root
    ../ci/fidelity-convert.sh >/dev/null 2>&1 && pass "converter cases match live Python" || fail "converter fidelity"
  else echo "  [skip] converter fidelity (app deps not importable — schema fidelity still ran)"; fi
else echo "  [skip] fidelity (python3 unavailable)"; fi

# ---- shared end-to-end scaffolding -------------------------------------------
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"; [ -n "${MOCK_PID:-}" ] && kill "$MOCK_PID" 2>/dev/null' EXIT
export DATABASE_URL="sqlite:///$WORK/app.db"
export ODYSSEUS_DATA_DIR="$WORK/data"
mkdir -p "$ODYSSEUS_DATA_DIR"
racket test/seed-db.rkt >/dev/null 2>&1 || fail "seed-db failed"

# run the agent for one scenario; $1=tool $2=arguments-json; echoes the agent JSON
agent_run(){
  printf '{"name":"%s","arguments":%s}' "$1" "$(printf '%s' "$2" | python3 -c 'import json,sys;print(json.dumps(sys.stdin.read()))' 2>/dev/null || printf '"%s"' "$(printf '%s' "$2" | sed 's/"/\\"/g')")" > "$CALL_FILE"
  LLM_ENDPOINT="http://127.0.0.1:$MOCK_PORT/v1/chat/completions" LLM_MODEL=mock \
    racket cli/odysseus-agent.rkt "integration: exercise $1" --owner alice --pretty --max-rounds 4 2>/dev/null
}
# assert the combined agent output contains a substring
expect(){ echo "$1" | grep -qF "$2" && pass "$3" || { echo "$1" | head -40; fail "$3"; }; }

echo "== 4/5  mock end-to-end (real loop + real DB) =="
export MOCK_PORT=8911 CALL_FILE="$WORK/call.json" MOCK_CALL_FILE="$WORK/call.json"
racket test/mock-llm.rkt >"$WORK/mock.log" 2>&1 &
MOCK_PID=$!
for i in $(seq 1 50); do curl -s -m1 "http://127.0.0.1:$MOCK_PORT/v1/chat/completions" -d '{}' >/dev/null 2>&1 && break; sleep 0.1; done

expect "$(agent_run manage_notes '{"action":"add","title":"IntgNote","checklist_items":[{"text":"x"}]}')" "Note created" "manage_notes add"
expect "$(agent_run manage_tasks '{"action":"create","prompt":"summarize","schedule":"daily","scheduled_time":"07:00"}')" "Created task" "manage_tasks create"
expect "$(agent_run manage_calendar '{"action":"create_event","summary":"IntgEvt","dtstart":"2026-06-20T09:00:00","reminder_minutes":30}')" "Created event" "manage_calendar create_event"
expect "$(agent_run manage_endpoints '{"action":"add","name":"IntgEp","base_url":"https://api.example/v1"}')" "Added endpoint" "manage_endpoints add"
expect "$(agent_run manage_skills '{"action":"add","name":"intg-skill","description":"d","procedure":["step one"]}')" "Created skill" "manage_skills add"
expect "$(agent_run manage_settings '{"action":"set","key":"search engine","value":"brave"}')" "Set search_provider = brave" "manage_settings set"
expect "$(agent_run manage_documents '{"action":"list"}')" "Meeting notes" "manage_documents list (seeded, owner-scoped)"

# persistence across processes: the note added above must be visible to a NEW agent process
expect "$(agent_run manage_notes '{"action":"list"}')" "IntgNote" "manage_notes persisted to disk (cross-process)"
# the calendar reminder Note must have been written by the create_event above
expect "$(agent_run manage_notes '{"action":"list"}')" "Reminder: IntgEvt" "calendar reminder note persisted"

kill "$MOCK_PID" 2>/dev/null; MOCK_PID=""

echo "== 5/5  live ollama (real model) =="
# Proves the LIVE path is wired: a real model over real HTTP issues a tool call
# that the agent executes against the real DB. We assert ONLY that >=1 manage_*
# tool call executed — not which one, nor that the model followed instructions
# perfectly: at 20 tools a 7B model is marginal at tool selection / termination
# (see PORTING_PLAN). Tool *selection* quality is a model property; this stage
# checks our wiring. Use a bigger/hosted model for a clean run.
if curl -s -m2 http://127.0.0.1:11434/api/version >/dev/null 2>&1; then
  MODEL="${LLM_MODEL_OLLAMA:-qwen2.5:7b}"
  if curl -s -m2 http://127.0.0.1:11434/api/tags | grep -q "$MODEL"; then
    res=$(LLM_ENDPOINT="http://127.0.0.1:11434/v1/chat/completions" LLM_MODEL="$MODEL" \
      racket cli/odysseus-agent.rkt "Use the manage_notes tool to create a checklist note titled 'Live Intg' with one item 'ship it'." \
      --owner alice --pretty --max-rounds 6 2>/dev/null)
    if echo "$res" | grep -qE '"tool": *"manage_'; then
      pass "live model issued a real tool call, executed end-to-end ($MODEL)"
      echo "$res" | grep -qF "Live Intg" \
        && pass "manage_notes created the note via live model" \
        || echo "  [note] model didn't land the exact note (tool selection varies at 20 tools); wiring verified"
    else
      echo "$res" | head -30
      echo "  [warn] live model issued no tool call — model-quality, not wiring (try LLM_MODEL_OLLAMA=qwen2.5:14b)"
      [ "${OLLAMA:-0}" = 1 ] && fail "OLLAMA=1 but live model issued no tool call"
    fi
  else echo "  [skip] ollama up but model '$MODEL' not pulled (set LLM_MODEL_OLLAMA)"; [ "${OLLAMA:-0}" = 1 ] && fail "OLLAMA=1 but model missing"; fi
else
  echo "  [skip] no ollama on :11434"; [ "${OLLAMA:-0}" = 1 ] && fail "OLLAMA=1 but :11434 unreachable"
fi

echo
echo "============================================================"
echo " INTEGRATION OK — compile, suite, fidelity, mock end-to-end$([ -n "${MOCK_PID:-}" ] || true)"
echo "============================================================"
