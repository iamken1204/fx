#!/bin/sh
# Replay the 2026-09-05 SIGTRAP shape headlessly: the parent sends one
# `subagent message` to a persistent child; the child loads a skill, runs
# PERSIST_ROUNDS batches of three parallel read-only calls over the real fx
# repo, then answers. GMALLOC=1 inserts libgmalloc so the first write into
# freed memory faults at the guilty instruction instead of surfacing later in
# malloc. usage: run-persist.sh <label>
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
LABEL=${1:-persist}; shift || true
REPO=$(cd "$HERE/../.." && pwd)
FX_BIN=${FX_BIN:-$REPO/zig-out/bin/fx}
PORT=${PORT:-47319}
PERSIST_ROUNDS=${PERSIST_ROUNDS:-1}
GMALLOC=${GMALLOC:-0}
ROOT="$HERE/out/$LABEL"
rm -rf "$ROOT"; mkdir -p "$ROOT/home/.fx/skills/unslop"
chmod 700 "$ROOT/home/.fx"

TOKEN=$(python3 -c 'import base64,json;p=base64.urlsafe_b64encode(json.dumps({"https://api.openai.com/auth":{"chatgpt_account_id":"acct_repro"}}).encode()).decode().rstrip("=");print("header."+p+".signature")')
EXP=$(python3 -c 'import time;print(int(time.time()*1000)+3600000)')
cat > "$ROOT/home/.fx/chatgpt-auth.json" <<EOF
{"version":1,"access_token":"$TOKEN","refresh_token":"chatgpt-refresh","expires_at_ms":$EXP,"account_id":"acct_repro"}
EOF
chmod 600 "$ROOT/home/.fx/chatgpt-auth.json"
cat > "$ROOT/home/.fx/settings.json" <<EOF
{"provider":"codex","credential_source":"fx_login","models":{"codex":"gpt-5.6-sol"},"effort":"high","permission_mode":"yolo","auto_upgrade":false,"collapse_tool_calls":true,"notifications":{"turn_end":false,"attention_required":false}}
EOF
cat > "$ROOT/home/.fx/skills/unslop/SKILL.md" <<'EOF'
---
name: unslop
description: Cure AI-sounding prose in anything written for a human.
---

Lead with the answer. Use active voice. Drop filler.
EOF

export PORT PERSIST PERSIST_ROUNDS PERSIST_PARENT_STEPS
PERSIST=1
PERSIST_PARENT_STEPS=${PERSIST_PARENT_STEPS:-0}
LOG="$ROOT/server.log" bun "$HERE/fake-codex.ts" 2>>"$ROOT/server.err" &
SERVER=$!
trap 'kill $SERVER 2>/dev/null || true' EXIT
sleep 0.6

if [ "$GMALLOC" = 1 ]; then
  INSERT=/usr/lib/libgmalloc.dylib
else
  INSERT=
fi

cd "$REPO"
env -i HOME="$ROOT/home" PATH="$PATH" TERM=xterm-256color LANG=en_US.UTF-8 \
  DYLD_INSERT_LIBRARIES="$INSERT" \
  MallocScribble=1 MallocPreScribble=1 \
  FX_AUTO_UPGRADE=0 \
  FX_TRACE_LOG="$ROOT/trace.log" FX_TRACE_SCOPES="agent,gateway,core" \
  FX_E2E_OPENAI_CODEX_RESPONSES_URL="http://127.0.0.1:$PORT/chatgpt/responses" \
  FX_E2E_OPENAI_CODEX_MODELS_URL="http://127.0.0.1:$PORT/chatgpt/models" \
  FX_E2E_CHATGPT_ISSUER_URL="http://127.0.0.1:$PORT" \
  FX_E2E_CHATGPT_TOKEN_URL="http://127.0.0.1:$PORT/chatgpt/token" \
  "$@" \
  "$FX_BIN" ask --yolo --no-color "PARENT-TASK: delegate the regression tests to the context-tests agent." \
  > "$ROOT/fx.out" 2> "$ROOT/fx.err" &
FX=$!
echo "$FX" > "$ROOT/fx.pid"
echo "fx pid=$FX"
wait $FX && echo "fx exit=0" >> "$ROOT/fx.err" || echo "fx exit=$?" >> "$ROOT/fx.err"
echo "=== $LABEL: server.log ==="; cat "$ROOT/server.log" 2>/dev/null | tail -12
echo "=== fx.err tail ==="; tail -5 "$ROOT/fx.err"
echo "=== fx.out tail ==="; tail -3 "$ROOT/fx.out"
