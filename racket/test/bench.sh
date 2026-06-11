#!/usr/bin/env bash
# racket/test/bench.sh — portable performance baseline for the Racket agent.
#
# Separates the two costs that matter, because they scale very differently
# across a gaming laptop / Apple-silicon / Raspberry Pi 4:
#
#   A. host info                  cpu / cores / RAM
#   B. racket startup             interpreter cold start (dominates tiny CLIs;
#                                 painful on a Pi — consider `raco exe`)
#   C. agent round vs mock LLM    the PORT's own overhead: loop + tool dispatch +
#                                 on-disk SQLite, with the model factored OUT
#                                 (a deterministic mock answers instantly)
#   D. LLM inference (ollama)     the real bottleneck: tokens/sec + model load,
#                                 per locally-available model, via /api/generate
#
# Run the SAME script on each machine and compare. Output is a plain table you
# can paste under the matching column in PERFORMANCE.md.
#
#   racket/test/bench.sh                 # B, C, and D for every pulled model
#   BENCH_MODELS="qwen2.5:1.5b" racket/test/bench.sh   # D for just these
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"
export PATH="$HOME/racket/bin:$PATH"
command -v racket >/dev/null || { echo "racket not on PATH"; exit 1; }

now(){ date +%s.%N; }
elapsed(){ awk "BEGIN{printf \"%.3f\", $2-$1}"; }

echo "================ Odysseus agent — perf baseline ================"
echo "## A. host"
echo "  uname : $(uname -srm)"
echo "  cores : $(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo '?')"
if [ -r /proc/meminfo ]; then
  echo "  RAM   : $(awk '/MemTotal/{printf "%.1f GB", $2/1048576}' /proc/meminfo)"
else
  echo "  RAM   : $(sysctl -n hw.memsize 2>/dev/null | awk '{printf "%.1f GB", $1/1073741824}' || echo '?')"
fi
echo "  racket: $(racket --version)"

echo "## B. racket startup (5 runs)"
b_sum=0; b_min=99
for i in 1 2 3 4 5; do
  s=$(now); racket -e '(void)' >/dev/null 2>&1; e=$(now)
  d=$(elapsed "$s" "$e"); b_sum=$(awk "BEGIN{print $b_sum+$d}")
  b_min=$(awk "BEGIN{print ($d<$b_min)?$d:$b_min}")
done
echo "  cold start: min ${b_min}s  avg $(awk "BEGIN{printf \"%.3f\", $b_sum/5}")s   (per CLI invocation)"

echo "## C. agent round vs mock LLM (model factored out; 3 runs, --tools manage_notes)"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"; [ -n "${MP:-}" ] && kill "$MP" 2>/dev/null' EXIT
export DATABASE_URL="sqlite:///$WORK/app.db" ODYSSEUS_DATA_DIR="$WORK/data"; mkdir -p "$WORK/data"
racket test/seed-db.rkt >/dev/null 2>&1
printf '{"name":"manage_notes","arguments":"{\\"action\\":\\"list\\"}"}' > "$WORK/call.json"
MOCK_PORT=8930 MOCK_CALL_FILE="$WORK/call.json" racket test/mock-llm.rkt >/dev/null 2>&1 & MP=$!
for i in $(seq 1 50); do curl -s -m1 http://127.0.0.1:8930/v1/chat/completions -d '{}' >/dev/null 2>&1 && break; sleep 0.1; done
c_sum=0; c_min=99
for i in 1 2 3; do
  s=$(now)
  LLM_ENDPOINT=http://127.0.0.1:8930/v1/chat/completions LLM_MODEL=mock \
    racket cli/odysseus-agent.rkt "bench" --owner alice --tools manage_notes --max-rounds 4 >/dev/null 2>&1
  e=$(now); d=$(elapsed "$s" "$e"); c_sum=$(awk "BEGIN{print $c_sum+$d}")
  c_min=$(awk "BEGIN{print ($d<$c_min)?$d:$c_min}")
done
c_avg=$(awk "BEGIN{printf \"%.3f\", $c_sum/3}")
echo "  full run  : min ${c_min}s  avg ${c_avg}s   (2 LLM round-trips + tool exec + DB, incl. startup)"
echo "  loop-only : ~$(awk "BEGIN{printf \"%.3f\", $c_avg-$b_min}")s   (full run minus one racket cold start)"
kill "$MP" 2>/dev/null; MP=""

echo "## D. LLM inference (ollama /api/generate, stream off)"
if curl -s -m2 http://127.0.0.1:11434/api/version >/dev/null 2>&1; then
  models="${BENCH_MODELS:-$(curl -s -m3 http://127.0.0.1:11434/api/tags \
            | python3 -c 'import sys,json;[print(m["name"]) for m in json.load(sys.stdin).get("models",[])]' 2>/dev/null)}"
  [ -z "$models" ] && echo "  (no models pulled)"
  for m in $models; do
    sz=$(curl -s -m3 http://127.0.0.1:11434/api/tags | python3 -c "
import sys,json
for x in json.load(sys.stdin).get('models',[]):
    if x['name']=='$m': print('%.2f GB'%(x['size']/1073741824)); break" 2>/dev/null)
    r=$(curl -s -m180 http://127.0.0.1:11434/api/generate \
        -d "{\"model\":\"$m\",\"prompt\":\"Write two sentences about the ocean.\",\"stream\":false,\"options\":{\"num_predict\":80}}")
    echo "$r" | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
    ed=d.get('eval_duration',0) or 1; ec=d.get('eval_count',0)
    ld=d.get('load_duration',0)/1e9; tot=d.get('total_duration',0)/1e9
    print('  %-22s %-9s  %6.1f tok/s   load %5.2fs   total %5.2fs  (gen %d tok)'%('$m','${sz:-?}', ec/(ed/1e9), ld, tot, ec))
except Exception as e:
    print('  %-22s  ERROR (model too big for RAM? OOM?): %s'%('$m', str(e)[:60]))"
  done
else
  echo "  (ollama not running on :11434 — start it to measure inference)"
fi
echo "==============================================================="
