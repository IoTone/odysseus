#!/usr/bin/env bash
# ci/fidelity-convert.sh — prove the Racket native-call→ToolBlock converter
# matches src/tool_schemas.py:function_call_to_tool_block. Needs the app venv
# (.venv) for the Python side. Content is compared SEMANTICALLY: JSON branches
# (Python json.dumps adds spaces; Racket doesn't) are parsed and compared as
# data; plain-string branches are compared exactly.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"

# Shared battery of (name, args) cases — covers every interesting branch.
CASES='[
 ["bash",{"command":"ls -la"}],
 ["shell",{"command":"pwd"}],
 ["python",{"code":"print(1)"}],
 ["web_search",{"query":"x","time_filter":"week"}],
 ["web_search",{"queries":["a","b"]}],
 ["web_search",{"query":"plain"}],
 ["read_file",{"path":"a.txt"}],
 ["read_file",{"path":"a.txt","offset":5}],
 ["grep",{"pattern":"foo","ignore_case":true}],
 ["glob",{"pattern":"**/*.rkt"}],
 ["ls",{}],
 ["write_file",{"path":"f.txt","content":"hi"}],
 ["edit_file",{"path":"f","old_string":"a","new_string":"b","replace_all":true}],
 ["create_document",{"title":"T","content":"body"}],
 ["create_document",{"title":"T","language":"python","content":"x=1"}],
 ["edit_document",{"edits":[{"find":"a","replace":"b"},{"find":"c","replace":"d"}]}],
 ["suggest_document",{"suggestions":[{"find":"a","replace":"b","reason":"r"}]}],
 ["update_document",{"content":"doc"}],
 ["search_chats",{"query":"q"}],
 ["pipeline",{"steps":[{"tool":"bash"}]}],
 ["manage_memory",{"action":"add","text":"hi","category":"fact"}],
 ["manage_memory",{"action":"list"}],
 ["manage_memory",{"action":"delete","memory_id":"m1"}],
 ["manage_notes",{"action":"add","title":"t","checklist_items":[{"text":"a","done":false}]}],
 ["todos",{"action":"list"}],
 ["manage_tasks",{"action":"create","prompt":"p","schedule":"daily","scheduled_time":"07:30"}],
 ["tasks",{"action":"list"}],
 ["manage_endpoints",{"action":"add","base_url":"https://api.x.ai/v1"}],
 ["endpoints",{"action":"list"}],
 ["manage_mcp",{"action":"add","name":"fs","command":"npx","args":["server-fs"],"env":{"A":"1"}}],
 ["manage_webhooks",{"action":"add","url":"https://example.com/h"}],
 ["webhooks",{"action":"list"}],
 ["manage_tokens",{"action":"list"}],
 ["tokens",{"action":"delete","token_id":"t1"}],
 ["manage_documents",{"action":"list","search":"notes"}],
 ["documents",{"action":"delete","document_id":"d1"}],
 ["manage_settings",{"action":"set","key":"search engine","value":"brave"}],
 ["preferences",{"action":"list"}],
 ["manage_skills",{"action":"add","name":"open-pr","procedure":["push","gh pr create"]}],
 ["skills",{"action":"view","name":"open-pr"}],
 ["manage_calendar",{"action":"create_event","summary":"Dentist","dtstart":"2026-06-11T09:00:00","reminder_minutes":30}],
 ["manage_calendar",{"action":"list_events"}],
 ["send_email",{"to":"a@b.c"}],
 ["frobnicate",{}],
 ["bash","NOT JSON"]
]'

python3 - "$CASES" <<'PY' > /tmp/py_conv.json
import sys, json
from src.agent_tools import function_call_to_tool_block as f
out=[]
for name,args in json.loads(sys.argv[1]):
    a = args if isinstance(args,str) else json.dumps(args)
    tb=f(name,a)
    out.append(None if tb is None else [tb.tool_type, tb.content])
print(json.dumps(out))
PY

racket racket/domain/tools/convert-cli.rkt "$CASES" > /tmp/rkt_conv.json

# Compare: same length; per case type byte-equal, content semantic (json|string).
python3 - <<'PY'
import json
py=json.load(open("/tmp/py_conv.json")); rk=json.load(open("/tmp/rkt_conv.json"))
def norm(c):
    try: return ("json", json.dumps(json.loads(c), sort_keys=True))
    except Exception: return ("str", c)
ok=True
assert len(py)==len(rk), f"length {len(py)} vs {len(rk)}"
for i,(p,r) in enumerate(zip(py,rk)):
    if p is None or r is None:
        if p!=r: ok=False; print(f"  ✗ case {i}: py={p} rk={r}")
        continue
    if p[0]!=r[0] or norm(p[1])!=norm(r[1]):
        ok=False; print(f"  ✗ case {i}: py={p} rk={r}")
print("[convert] all", len(py), "cases match (type exact, content semantic) ✓" if ok else "[convert] MISMATCH")
import sys; sys.exit(0 if ok else 1)
PY