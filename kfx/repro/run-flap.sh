#!/bin/sh
# Reproduce the incident's network-flap fingerprint through the real TUI:
# every step's first attempt is interrupted mid-reasoning and the retry
# succeeds. fx runs under MallocStackLogging so malloc_history can attribute
# live bytes while the run is still going. usage: run-flap.sh <label>
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
LABEL=${1:-flap}
FX_BIN=${FX_BIN:-$(cd "$HERE/../.." && pwd)/zig-out/bin/fx}
PORT=${PORT:-47313}
STEPS=${STEPS:-300}
DELTAS=${DELTAS:-3000}
CUT_BYTES=${CUT_BYTES:-131072}
FIXTURE_KB=${FIXTURE_KB:-20}
TIMEOUT_S=${TIMEOUT_S:-1200}
COMPACT=${COMPACT:-1}
MALLOC_STACK=${MALLOC_STACK:-lite}
ROOT="$HERE/out/$LABEL"
SOCK="fxrepro-$LABEL"
rm -rf "$ROOT"; mkdir -p "$ROOT/home/.fx" "$ROOT/ws"
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

i=1
while [ "$i" -le "$STEPS" ]; do
  python3 -c "import sys;sys.stdout.write(('fixture $i line of text to read\n'*2000)[:$FIXTURE_KB*1024])" > "$ROOT/ws/fixture-$i.txt"
  i=$((i+1))
done

export PORT STEPS DELTAS CUT_BYTES
FLAP=1 LOG="$ROOT/server.log" bun "$HERE/fake-codex.ts" 2>>"$ROOT/server.err" &
SERVER=$!
cleanup() { kill $SERVER 2>/dev/null || true; tmux -L "$SOCK" kill-server 2>/dev/null || true; }
trap cleanup EXIT
sleep 0.6

cat > "$ROOT/launch.sh" <<EOF
#!/bin/sh
cd "$ROOT/ws"
exec env -i HOME="$ROOT/home" PATH="$PATH" TERM=xterm-256color LANG=en_US.UTF-8 COLORTERM=truecolor \\
  MallocStackLogging=$MALLOC_STACK \\
  FX_TRACE_LOG="$ROOT/trace.log" FX_TRACE_SCOPES="agent,gateway" \\
  FX_AUTO_UPGRADE=0 \\
  FX_COMPACT_TOOL_CALLS=$COMPACT \\
  FX_E2E_OPENAI_CODEX_RESPONSES_URL="http://127.0.0.1:$PORT/chatgpt/responses" \\
  FX_E2E_OPENAI_CODEX_MODELS_URL="http://127.0.0.1:$PORT/chatgpt/models" \\
  FX_E2E_CHATGPT_ISSUER_URL="http://127.0.0.1:$PORT" \\
  FX_E2E_CHATGPT_TOKEN_URL="http://127.0.0.1:$PORT/chatgpt/token" \\
  "$FX_BIN" 2> "$ROOT/fx.err"
EOF
chmod +x "$ROOT/launch.sh"

tmux -L "$SOCK" new-session -d -s repro -x 160 -y 48 "$ROOT/launch.sh"
sleep 2.5
tmux -L "$SOCK" capture-pane -p -t repro > "$ROOT/pane-start.txt"
PANE_PID=$(tmux -L "$SOCK" display-message -p -t repro '#{pane_pid}')
FX=$(pgrep -P "$PANE_PID" | head -1); [ -z "$FX" ] && FX=$PANE_PID
echo "$FX" > "$ROOT/fx.pid"
echo "fx pid=$FX (pane_pid=$PANE_PID)"; ps -o pid,rss,command -p "$FX" | tail -1 | cut -c1-120
tmux -L "$SOCK" send-keys -t repro -l -- "Read every fixture-N.txt file in this directory, one per step."
tmux -L "$SOCK" send-keys -t repro Enter

sh "$HERE/memwatch.sh" "$FX" "$ROOT/mem.csv" "${SAMPLE:-1}" &
WATCH=$!
start=$(date +%s)
while kill -0 "$FX" 2>/dev/null; do
  if tmux -L "$SOCK" capture-pane -p -t repro 2>/dev/null | grep -q "All fixtures read"; then break; fi
  if [ $(( $(date +%s) - start )) -ge "$TIMEOUT_S" ]; then echo "timeout"; break; fi
  sleep 2
done
tmux -L "$SOCK" capture-pane -p -S -60 -t repro > "$ROOT/pane-end.txt" 2>/dev/null || true
sleep 1
tmux -L "$SOCK" send-keys -t repro -l -- "/quit"; tmux -L "$SOCK" send-keys -t repro Enter; sleep 1
kill $WATCH 2>/dev/null || true; wait $WATCH 2>/dev/null || true
echo "=== $LABEL: requests=$(grep -c '^request' "$ROOT/server.log" 2>/dev/null) last=$(grep '^request' "$ROOT/server.log" | tail -1)"
echo "=== peak rss_mb === $(awk -F, 'NR>1 && $2>m {m=$2} END {print m}' "$ROOT/mem.csv") samples=$(wc -l < "$ROOT/mem.csv")"
awk -F, 'NR>1 {n++; a[n]=$0} END {for(i=1;i<=n;i+=int(n/10)+1) print a[i]; print a[n]}' "$ROOT/mem.csv"
echo "=== pane end (tail) ==="; tail -12 "$ROOT/pane-end.txt"
