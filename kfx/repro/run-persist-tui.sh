#!/bin/sh
# Replay a recorded incident (REPLAY=<script.json> from make-replay.py) through
# the real fx TUI inside tmux, the surface the 2026-09-05 SIGTRAP ran on. A
# pending ask_user_question dialog is answered with its first option. GMALLOC=1
# inserts libgmalloc so a write into freed memory faults at the guilty
# instruction. usage: run-persist-tui.sh <label> [extra env assignments...]
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
LABEL=${1:-persist-tui}; shift || true
REPO=$(cd "$HERE/../.." && pwd)
FX_BIN=${FX_BIN:-$REPO/zig-out/bin/fx}
PORT=${PORT:-47323}
TIMEOUT_S=${TIMEOUT_S:-600}
GMALLOC=${GMALLOC:-0}
ROOT="$HERE/out/$LABEL"
SOCK="fxrepro-$LABEL"
rm -rf "$ROOT"; mkdir -p "$ROOT/home/.fx/skills/unslop"
chmod 700 "$ROOT/home/.fx"

TOKEN=$(python3 -c 'import base64,json;p=base64.urlsafe_b64encode(json.dumps({"https://api.openai.com/auth":{"chatgpt_account_id":"acct_repro"}}).encode()).decode().rstrip("=");print("header."+p+".signature")')
EXP=$(python3 -c 'import time;print(int(time.time()*1000)+3600000)')
cat > "$ROOT/home/.fx/chatgpt-auth.json" <<EOF
{"version":1,"access_token":"$TOKEN","refresh_token":"chatgpt-refresh","expires_at_ms":$EXP,"account_id":"acct_repro"}
EOF
chmod 600 "$ROOT/home/.fx/chatgpt-auth.json"
cat > "$ROOT/home/.fx/settings.json" <<EOF
{"effort":"high","statusLine":{"sandbox":true,"context":true,"session":true,"workspace":true},"notifications":{"turn_end":false,"attention_required":false,"max":false},"provider":"codex","fast_mode":false,"permission_mode":"yolo","credential_source":"fx_login","models":{"codex":"gpt-5.6-sol"},"context_limits":{"skill_catalog_bytes":65536},"auto_upgrade":false,"collapse_tool_calls":true,"yolo_acknowledged":true}
EOF
cat > "$ROOT/home/.fx/skills/unslop/SKILL.md" <<'EOF'
---
name: unslop
description: Cure AI-sounding prose in anything written for a human.
---

Lead with the answer. Use active voice. Drop filler.
EOF

export PORT PERSIST REPLAY
PERSIST=1
LOG="$ROOT/server.log" bun "$HERE/fake-codex.ts" 2>>"$ROOT/server.err" &
SERVER=$!
cleanup() { kill $SERVER 2>/dev/null || true; tmux -L "$SOCK" kill-server 2>/dev/null || true; }
trap cleanup EXIT
sleep 0.6

if [ "$GMALLOC" = 1 ]; then INSERT=/usr/lib/libgmalloc.dylib; else INSERT=; fi
EXTRA=""
for kv in "$@"; do EXTRA="$EXTRA $kv"; done

cat > "$ROOT/launch.sh" <<EOF
#!/bin/sh
cd "$REPO"
exec env -i HOME="$ROOT/home" PATH="$PATH" TERM=xterm-256color LANG=en_US.UTF-8 COLORTERM=truecolor \\
  DYLD_INSERT_LIBRARIES="$INSERT" MallocScribble=1 MallocPreScribble=1 \\
  FX_AUTO_UPGRADE=0 FX_TRACE_LOG="$ROOT/trace.log" FX_TRACE_SCOPES="agent,gateway,core" \\
  FX_E2E_OPENAI_CODEX_RESPONSES_URL="http://127.0.0.1:$PORT/chatgpt/responses" \\
  FX_E2E_OPENAI_CODEX_MODELS_URL="http://127.0.0.1:$PORT/chatgpt/models" \\
  FX_E2E_CHATGPT_ISSUER_URL="http://127.0.0.1:$PORT" \\
  FX_E2E_CHATGPT_TOKEN_URL="http://127.0.0.1:$PORT/chatgpt/token" \\
  $EXTRA \\
  "$FX_BIN" 2> "$ROOT/fx.err"
echo "fx exit=\$?" >> "$ROOT/fx.err"
EOF
chmod +x "$ROOT/launch.sh"

tmux -L "$SOCK" new-session -d -s repro -x 180 -y 50 "$ROOT/launch.sh"
sleep 3
tmux -L "$SOCK" capture-pane -p -t repro > "$ROOT/pane-start.txt"
PANE_PID=$(tmux -L "$SOCK" display-message -p -t repro '#{pane_pid}')
FX=$(pgrep -P "$PANE_PID" | head -1); [ -z "$FX" ] && FX=$PANE_PID
echo "fx pid=$FX (pane_pid=$PANE_PID)"
tmux -L "$SOCK" send-keys -t repro -l -- "PARENT-TASK: delegate the regression tests to the context-tests agent."
tmux -L "$SOCK" send-keys -t repro Enter

start=$(date +%s)
answered=0
while kill -0 "$FX" 2>/dev/null; do
  pane=$(tmux -L "$SOCK" capture-pane -p -t repro 2>/dev/null || true)
  if printf '%s' "$pane" | grep -q "All fixtures read"; then break; fi
  # The question dialog lists options; pick the first with Enter once.
  if [ "$answered" = 0 ] && printf '%s' "$pane" | grep -q "建立獨立 worktree"; then
    sleep 0.5; tmux -L "$SOCK" send-keys -t repro Enter; answered=1
    printf '%s\n' "$pane" > "$ROOT/pane-question.txt"
  fi
  if [ $(( $(date +%s) - start )) -ge "$TIMEOUT_S" ]; then echo "timeout"; break; fi
  sleep 1
done
tmux -L "$SOCK" capture-pane -p -S -80 -t repro > "$ROOT/pane-end.txt" 2>/dev/null || true
sleep 1
if kill -0 "$FX" 2>/dev/null; then
  tmux -L "$SOCK" send-keys -t repro -l -- "/quit"; tmux -L "$SOCK" send-keys -t repro Enter; sleep 2
fi
echo "=== $LABEL: requests=$(grep -c '^request' "$ROOT/server.log" 2>/dev/null) last=$(grep '^request' "$ROOT/server.log" | tail -1)"
echo "=== fx.err tail ==="; grep -v GuardMalloc "$ROOT/fx.err" | tail -4
echo "=== pane end (tail) ==="; tail -8 "$ROOT/pane-end.txt"
