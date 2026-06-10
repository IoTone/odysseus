#!/usr/bin/env bash
# ci/fidelity-tools.sh — prove the Racket define-tool DSL emits schemas
# byte-identical to src/tool_schemas.py's FUNCTION_TOOL_SCHEMAS, for the ported
# tools. No venv needed: the Python list is a pure literal, read via
# ast.literal_eval (we never import the module).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"

names='bash python web_search web_fetch read_file grep glob ls write_file edit_file manage_notes manage_tasks'

python3 - "$names" <<'PY' > /tmp/py_tools.json
import ast, json, sys
names=set(sys.argv[1].split())
tree=ast.parse(open("src/tool_schemas.py").read())
node=next(n.value for n in tree.body if isinstance(n,ast.Assign)
         and any(getattr(t,'id',None)=="FUNCTION_TOOL_SCHEMAS" for t in n.targets))
sub={s["function"]["name"]:s for s in ast.literal_eval(node) if s["function"]["name"] in names}
print(json.dumps(sub, sort_keys=True, indent=2))
PY

racket racket/domain/tools/core-tools.rkt \
  | python3 -c 'import sys,json;a=json.load(sys.stdin);print(json.dumps({s["function"]["name"]:s for s in a},sort_keys=True,indent=2))' \
  > /tmp/rkt_tools.json

if diff -q /tmp/py_tools.json /tmp/rkt_tools.json >/dev/null; then
  echo "[tools] all ported tool schemas byte-identical to FUNCTION_TOOL_SCHEMAS ✓"
  rm -f /tmp/py_tools.json /tmp/rkt_tools.json
else
  echo "[tools] MISMATCH:"; diff /tmp/py_tools.json /tmp/rkt_tools.json; exit 1
fi
