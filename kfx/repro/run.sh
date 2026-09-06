#!/bin/sh
# Run fx ask (headless) against the fake codex server in an isolated HOME and
# sample RSS. usage: run.sh <label> [extra env assignments...]
# Requires: bun, ./zig-out/bin/fx built in the fx repo (FX_BIN overrides).
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
LABEL=${1:-run}; shift || true
FX_BIN=${FX_BIN:-$(cd "$HERE/../.." && pwd)/zig-out/bin/fx}
PORT=${PORT:-47311}
STEPS=${STEPS:-30}
FIXTURE_KB=${FIXTURE_KB:-20}
ROOT="$HERE/out/$LABEL"
rm -rf "$ROOT"; mkdir -p "$ROOT/home/.fx" "$ROOT/ws"
chmod 700 "$ROOT/home/.fx"

# Fake ChatGPT login: the codex client only decodes the JWT payload claim.
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

export PORT STEPS
LOG="$ROOT/server.log" bun "$HERE/fake-codex.ts" 2>>"$ROOT/server.err" &
SERVER=$!
trap 'kill $SERVER 2>/dev/null || true' EXIT
sleep 0.6

cd "$ROOT/ws"
env -i HOME="$ROOT/home" PATH="$PATH" TERM=xterm-256color LANG=en_US.UTF-8 \
  FX_AUTO_UPGRADE=0 \
  FX_E2E_OPENAI_CODEX_RESPONSES_URL="http://127.0.0.1:$PORT/chatgpt/responses" \
  FX_E2E_OPENAI_CODEX_MODELS_URL="http://127.0.0.1:$PORT/chatgpt/models" \
  FX_E2E_CHATGPT_ISSUER_URL="http://127.0.0.1:$PORT" \
  FX_E2E_CHATGPT_TOKEN_URL="http://127.0.0.1:$PORT/chatgpt/token" \
  "$@" \
  "$FX_BIN" ask --yolo --no-color "Read every fixture-N.txt file in this directory, one per step." \
  > "$ROOT/fx.out" 2> "$ROOT/fx.err" &
FX=$!
sh "$HERE/memwatch.sh" "$FX" "$ROOT/mem.csv" ${SAMPLE:-0.5}
wait $FX || echo "fx exit=$?" >> "$ROOT/fx.err"
echo "=== $LABEL: server.log tail ==="; tail -3 "$ROOT/server.log" 2>/dev/null || true
echo "=== mem.csv (first 3 / last 3) ==="; head -4 "$ROOT/mem.csv"; tail -3 "$ROOT/mem.csv"
echo "=== peak rss_mb ==="; awk -F, 'NR>1 && $2>m {m=$2} END {print m}' "$ROOT/mem.csv"
echo "=== fx.err tail ==="; tail -5 "$ROOT/fx.err"
echo "=== fx.out tail ==="; tail -5 "$ROOT/fx.out"
