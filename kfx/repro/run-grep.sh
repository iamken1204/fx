#!/bin/sh
# Reproduce the incident's tool workload: headless fx ask running grep_files
# over the real fx repo, one search per step, RSS sampled, malloc stack
# logging enabled for live attribution. usage: run-grep.sh <label>
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
LABEL=${1:-grep}; shift || true
REPO=$(cd "$HERE/../.." && pwd)
FX_BIN=${FX_BIN:-$REPO/zig-out/bin/fx}
PORT=${PORT:-47315}
STEPS=${STEPS:-50}
MALLOC_STACK=${MALLOC_STACK:-lite}
ROOT="$HERE/out/$LABEL"
rm -rf "$ROOT"; mkdir -p "$ROOT/home/.fx"
chmod 700 "$ROOT/home/.fx"

TOKEN=$(python3 -c 'import base64,json;p=base64.urlsafe_b64encode(json.dumps({"https://api.openai.com/auth":{"chatgpt_account_id":"acct_repro"}}).encode()).decode().rstrip("=");print("header."+p+".signature")')
EXP=$(python3 -c 'import time;print(int(time.time()*1000)+3600000)')
cat > "$ROOT/home/.fx/chatgpt-auth.json" <<EOF
{"version":1,"access_token":"$TOKEN","refresh_token":"chatgpt-refresh","expires_at_ms":$EXP,"account_id":"acct_repro"}
EOF
chmod 600 "$ROOT/home/.fx/chatgpt-auth.json"
cat > "$ROOT/home/.fx/settings.json" <<EOF
{"provider":"codex","credential_source":"fx_login","models":{"codex":"gpt-5.6-sol"},"effort":"high","permission_mode":"auto","auto_upgrade":false,"notifications":{"turn_end":false,"attention_required":false}}
EOF

export PORT STEPS CHILDREN CHILD_STEPS INSPECT_WAIT RATE_LIMIT_EVERY
CHILDREN=${CHILDREN:-0}; CHILD_STEPS=${CHILD_STEPS:-$STEPS}; RATE_LIMIT_EVERY=${RATE_LIMIT_EVERY:-0}; INSPECT_WAIT=${INSPECT_WAIT:-0}
TOOL=grep_files LOG="$ROOT/server.log" bun "$HERE/fake-codex.ts" 2>>"$ROOT/server.err" &
SERVER=$!
trap 'kill $SERVER 2>/dev/null || true' EXIT
sleep 0.6

cd "$REPO"
env -i HOME="$ROOT/home" PATH="$PATH" TERM=xterm-256color LANG=en_US.UTF-8 \
  MallocStackLogging=$MALLOC_STACK \
  FX_AUTO_UPGRADE=0 \
  FX_TRACE_LOG="$ROOT/trace.log" FX_TRACE_SCOPES="agent,gateway,core" \
  FX_E2E_OPENAI_CODEX_RESPONSES_URL="http://127.0.0.1:$PORT/chatgpt/responses" \
  FX_E2E_OPENAI_CODEX_MODELS_URL="http://127.0.0.1:$PORT/chatgpt/models" \
  FX_E2E_CHATGPT_ISSUER_URL="http://127.0.0.1:$PORT" \
  FX_E2E_CHATGPT_TOKEN_URL="http://127.0.0.1:$PORT/chatgpt/token" \
  "$FX_BIN" ask --yolo --no-color "PARENT-TASK: search the repo for each requested pattern, one per step." \
  > "$ROOT/fx.out" 2> "$ROOT/fx.err" &
FX=$!
echo "$FX" > "$ROOT/fx.pid"
echo "fx pid=$FX"
sh "$HERE/memwatch.sh" "$FX" "$ROOT/mem.csv" ${SAMPLE:-0.5}
wait $FX || echo "fx exit=$?" >> "$ROOT/fx.err"
echo "=== $LABEL: server.log tail ==="; tail -3 "$ROOT/server.log" 2>/dev/null || true
echo "=== peak rss_mb / footprint_mb ==="; awk -F, 'NR>1 && $2>m {m=$2} NR>1 && $5>f {f=$5} END {print m, f}' "$ROOT/mem.csv"
awk -F, 'NR>1 {n++; a[n]=$0} END {for(i=1;i<=n;i+=int(n/10)+1) print a[i]; print a[n]}' "$ROOT/mem.csv"
echo "=== fx.err tail ==="; tail -3 "$ROOT/fx.err"
