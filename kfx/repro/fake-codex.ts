// Fake OpenAI Codex Responses endpoint for fx memory reproduction.
// Each request streams DELTAS reasoning deltas, one encrypted reasoning item,
// then a read_file tool call for the first STEPS requests and a final text after.
// FLAP=1 reproduces the incident's network-flap fingerprint: a raw TCP proxy
// sits on PORT in front of the HTTP server and hard-terminates every odd
// /chatgpt/responses connection after CUT_BYTES of response bytes, mid
// reasoning stream, before any tool event. fx sees a truncated chunked body
// (a retryable transport error, matching the incident's network_interrupted /
// retrying_request checkpoints) and the retried attempt passes through intact.
// CHILDREN=N makes the parent's first response spawn N one-off subagents (each
// runs CHILD_STEPS tool steps); sessions are told apart by the first user
// message, so the parent prompt must not contain "CHILD-TASK".
// RATE_LIMIT_EVERY=N answers every Nth step of each session with one HTTP 429
// before serving it, exercising the bounded retry path.
// env: PORT STEPS DELTAS DELTA_BYTES ENC_BYTES PACE_MS PACE_EVERY FLAP CUT_BYTES
//      CHILDREN CHILD_STEPS INSPECT_WAIT RATE_LIMIT_EVERY LOG
const PORT = Number(process.env.PORT ?? 47311);
const STEPS = Number(process.env.STEPS ?? 30);
const DELTAS = Number(process.env.DELTAS ?? 3000);
const DELTA_BYTES = Number(process.env.DELTA_BYTES ?? 24);
const ENC_BYTES = Number(process.env.ENC_BYTES ?? 8192);
const PACE_MS = Number(process.env.PACE_MS ?? 0);
const PACE_EVERY = Number(process.env.PACE_EVERY ?? 50);
const FLAP = Number(process.env.FLAP ?? 0);
const CUT_BYTES = Number(process.env.CUT_BYTES ?? 128 * 1024);
const TOOL = process.env.TOOL ?? "read_file";
const CHILDREN = Number(process.env.CHILDREN ?? 0);
const CHILD_STEPS = Number(process.env.CHILD_STEPS ?? STEPS);
const RATE_LIMIT_EVERY = Number(process.env.RATE_LIMIT_EVERY ?? 0);
// INSPECT_WAIT=N makes the parent follow each create with N `subagent inspect`
// calls per child that wait up to 60 s for the child to settle, the shape the
// incident parent was in when the kernel killed it.
const INSPECT_WAIT = Number(process.env.INSPECT_WAIT ?? 0);
const LOG = process.env.LOG ?? "/dev/stderr";
const HTTP_PORT = FLAP > 0 ? PORT + 1 : PORT;

// Pattern mix modeled on the incident turn's repo searches: targeted
// identifier queries plus a few high-hit patterns that exercise the
// collection caps.
const grep_patterns = [
  "snapshotContextHistory",
  "appendHistoryTurnProjection",
  "ephemeral_overlay",
  "max_history_turns",
  "recovery_checkpoint",
  "persistRecoveryCheckpoint",
  "ArenaAllocator",
  "pub fn",
  "alloc",
  "arena",
];

const models = [
  {
    slug: "gpt-5.6-sol",
    visibility: "list",
    supported_in_api: true,
    supported_reasoning_levels: [{ effort: "max" }, { effort: "high" }],
    additional_speed_tiers: ["fast"],
    input_modalities: ["text", "image"],
    context_window: 272000,
  },
];

const delta = "reasoning ".repeat(Math.ceil(DELTA_BYTES / 10)).slice(0, DELTA_BYTES);
const encrypted = "A".repeat(ENC_BYTES);
let requests = 0;
const sessions = new Map<string, { n: number; limited: Set<number> }>();

function childIds(body: string): string[] {
  const ids: string[] = [];
  try {
    for (const item of JSON.parse(body).input as { type?: string; output?: string }[]) {
      if (item.type !== "function_call_output" || !item.output?.includes("child_id")) continue;
      const id = JSON.parse(item.output).child_id;
      if (typeof id === "string" && !ids.includes(id)) ids.push(id);
    }
  } catch {}
  return ids;
}

function sessionKey(body: string): string {
  try {
    const input = JSON.parse(body).input as { type?: string; role?: string; content?: { text?: string }[] | string }[];
    for (const item of input) {
      if (item.role !== "user") continue;
      const text = typeof item.content === "string" ? item.content : item.content?.map((part) => part.text ?? "").join("") ?? "";
      const match = /CHILD-TASK-\d+/.exec(text);
      if (match) return match[0];
    }
    return "parent";
  } catch {
    return "parent";
  }
}

function toolCall(n: number, index: number, name: string, args: string) {
  return { type: "function_call", id: `fc_${n}_${index}`, call_id: `call_${n}_${index}`, name, arguments: args };
}

import { appendFileSync } from "node:fs";
function log(line: string) {
  try { appendFileSync(LOG, line + "\n"); } catch {}
  console.error(line);
}

function sseEvent(obj: unknown): string {
  return `data: ${JSON.stringify(obj)}\n\n`;
}

function respond(session: string, n: number, bodyBytes: number, children: string[]): Response {
  const encoder = new TextEncoder();
  const stream = new ReadableStream<Uint8Array>({
    async start(controller) {
      const push = (s: string) => controller.enqueue(encoder.encode(s));
      const id = `resp_${session}_${n}`;
      push(sseEvent({ type: "response.created", response: { id } }));
      push(sseEvent({ type: "response.output_item.added", output_index: 0, item: { type: "reasoning", id: `rs_${n}` } }));
      for (let i = 0; i < DELTAS; i++) {
        push(sseEvent({ type: "response.reasoning_summary_text.delta", output_index: 0, delta }));
        if (PACE_MS > 0 && i % PACE_EVERY === 0) await Bun.sleep(PACE_MS);
      }
      push(sseEvent({ type: "response.reasoning_summary_part.done", output_index: 0 }));
      push(sseEvent({
        type: "response.output_item.done",
        output_index: 0,
        item: { type: "reasoning", id: `rs_${n}`, encrypted_content: encrypted, summary: [] },
      }));
      const output: unknown[] = [{ type: "reasoning", id: `rs_${n}`, encrypted_content: encrypted, summary: [] }];
      const steps = session === "parent" ? STEPS : CHILD_STEPS;
      const calls: ReturnType<typeof toolCall>[] = [];
      if (session === "parent" && CHILDREN > 0 && n === 1) {
        for (let c = 1; c <= CHILDREN; c++) {
          calls.push(toolCall(n, c, "subagent", JSON.stringify({ command: { create: {
            name: `child-${c}`,
            mode: "one_off",
            prompt: `CHILD-TASK-${c}: search the repo for each requested pattern, one per step.`,
          } } })));
        }
      } else if (session === "parent" && INSPECT_WAIT > 0 && children.length > 0 && n - 2 < INSPECT_WAIT * children.length) {
        const child = children[(n - 2) % children.length];
        calls.push(toolCall(n, 1, "subagent", JSON.stringify({ command: { inspect: {
          id: child,
          sections: ["status", "messages", "events", "tool_activity"],
          wait: { until: "settled", timeout_ms: 60000 },
        } } })));
      } else if (n <= steps) {
        const args = TOOL === "grep_files"
          ? JSON.stringify({ pattern: grep_patterns[n % grep_patterns.length], path: "." })
          : JSON.stringify({ path: `fixture-${n}.txt` });
        calls.push(toolCall(n, 1, TOOL, args));
      }
      if (calls.length > 0) {
        for (const [i, item] of calls.entries()) {
          const output_index = 1 + i;
          push(sseEvent({ type: "response.output_item.added", output_index, item: { ...item, arguments: "" } }));
          push(sseEvent({ type: "response.function_call_arguments.delta", output_index, delta: item.arguments }));
          push(sseEvent({ type: "response.function_call_arguments.done", output_index, arguments: item.arguments }));
          push(sseEvent({ type: "response.output_item.done", output_index, item }));
          output.push(item);
        }
      } else {
        push(sseEvent({ type: "response.output_item.added", output_index: 1, item: { type: "message", id: `msg_${n}`, role: "assistant" } }));
        push(sseEvent({ type: "response.output_text.delta", output_index: 1, delta: "All fixtures read. Done." }));
        output.push({ type: "message", id: `msg_${n}`, role: "assistant", content: [{ type: "output_text", text: "All fixtures read. Done." }] });
      }
      push(sseEvent({
        type: "response.completed",
        response: {
          id,
          status: "completed",
          output,
          usage: { input_tokens: 1000 + n * 200, output_tokens: 500, output_tokens_details: { reasoning_tokens: 400 } },
        },
      }));
      push("data: [DONE]\n\n");
      controller.close();
      log(`response ${session}/${n} done body_bytes=${bodyBytes} deltas=${DELTAS}`);
    },
  });
  return new Response(stream, { headers: { "content-type": "text/event-stream" } });
}

// One relay direction with correct partial-write handling: socket.write may
// accept fewer bytes than offered, so the remainder is queued and resumed from
// the drain callback. Dropping the remainder would truncate uninjected
// connections too and turn every attempt into ReadFailed.
type Relay = {
  queue: Uint8Array[];
  source_closed: boolean;
  budget: number; // bytes still allowed through; Infinity when not cutting
  on_budget_exhausted: (() => void) | null;
};

function makeRelay(): Relay {
  return { queue: [], source_closed: false, budget: Infinity, on_budget_exhausted: null };
}

function pumpRelay(relay: Relay, sink: { write(data: Uint8Array): number; end(): void }) {
  while (relay.queue.length > 0) {
    const head = relay.queue[0];
    let written: number;
    try {
      written = sink.write(head);
    } catch {
      return;
    }
    if (written < head.length) {
      relay.queue[0] = head.subarray(written);
      return;
    }
    relay.queue.shift();
  }
  if (relay.queue.length === 0 && relay.budget <= 0 && relay.on_budget_exhausted) {
    const fire = relay.on_budget_exhausted;
    relay.on_budget_exhausted = null;
    fire();
    return;
  }
  if (relay.source_closed && relay.queue.length === 0) {
    try { sink.end(); } catch {}
  }
}

function relayPush(relay: Relay, chunk: Uint8Array, sink: { write(data: Uint8Array): number; end(): void }) {
  if (relay.budget <= 0) return;
  const admitted = chunk.length > relay.budget ? chunk.subarray(0, relay.budget) : chunk;
  relay.budget -= admitted.length;
  relay.queue.push(new Uint8Array(admitted));
  pumpRelay(relay, sink);
}

type ProxyState = {
  upstream: import("bun").Socket<unknown> | null;
  to_upstream: Relay;
  to_client: Relay;
  flap: boolean;
  classified: boolean;
  connection: number;
};

let responses_connections = 0;

if (FLAP > 0) {
  Bun.listen<ProxyState>({
    hostname: "127.0.0.1",
    port: PORT,
    socket: {
      open(client) {
        client.data = {
          upstream: null,
          to_upstream: makeRelay(),
          to_client: makeRelay(),
          flap: false,
          classified: false,
          connection: 0,
        };
        Bun.connect({
          hostname: "127.0.0.1",
          port: HTTP_PORT,
          socket: {
            data(upstream, chunk) {
              relayPush(client.data.to_client, chunk, client);
            },
            drain(upstream) {
              pumpRelay(client.data.to_upstream, upstream);
            },
            close() {
              const state = client.data;
              state.to_client.source_closed = true;
              pumpRelay(state.to_client, client);
            },
            error() {
              try { client.terminate(); } catch {}
            },
          },
        }).then((upstream) => {
          const state = client.data;
          state.upstream = upstream;
          pumpRelay(state.to_upstream, upstream);
        }).catch((err) => {
          log(`proxy upstream connect failed: ${err}`);
          try { client.terminate(); } catch {}
        });
      },
      data(client, chunk) {
        const state = client.data;
        if (!state.classified) {
          state.classified = true;
          const head = new TextDecoder().decode(chunk.subarray(0, 128));
          if (head.includes("/chatgpt/responses")) {
            responses_connections += 1;
            state.connection = responses_connections;
            state.flap = responses_connections % 2 === 1;
            if (state.flap) {
              state.to_client.budget = CUT_BYTES;
              state.to_client.on_budget_exhausted = () => {
                log(`proxy flap-cut connection ${state.connection} after ${CUT_BYTES} bytes`);
                try { client.terminate(); } catch {}
                try { state.upstream?.terminate(); } catch {}
              };
            }
          }
        }
        if (state.upstream) relayPush(state.to_upstream, chunk, state.upstream);
        else state.to_upstream.queue.push(new Uint8Array(chunk));
      },
      drain(client) {
        pumpRelay(client.data.to_client, client);
      },
      close(client) {
        const state = client.data;
        state.to_upstream.source_closed = true;
        if (state.upstream) pumpRelay(state.to_upstream, state.upstream);
      },
      error(client) {
        try { client.data?.upstream?.terminate(); } catch {}
      },
    },
  });
}

Bun.serve({
  port: HTTP_PORT,
  hostname: "127.0.0.1",
  async fetch(request) {
    const url = new URL(request.url);
    if (url.pathname === "/chatgpt/models") return Response.json({ models });
    if (url.pathname === "/chatgpt/token") {
      return Response.json({ access_token: "unused", refresh_token: "unused", expires_in: 3600 });
    }
    if (url.pathname === "/chatgpt/responses") {
      const body = await request.text();
      requests += 1;
      if (process.env.DUMP === "1") appendFileSync(`${LOG}.req${requests}.json`, body);
      const key = sessionKey(body);
      const session = sessions.get(key) ?? { n: 0, limited: new Set<number>() };
      sessions.set(key, session);
      const step = session.n + 1;
      if (RATE_LIMIT_EVERY > 0 && step % RATE_LIMIT_EVERY === 0 && !session.limited.has(step)) {
        session.limited.add(step);
        log(`request ${requests} ${key}/${step} body_bytes=${body.length} -> 429`);
        return new Response('{"error":{"message":"rate limited"}}', { status: 429, headers: { "content-type": "application/json" } });
      }
      session.n = step;
      log(`request ${requests} ${key}/${step} body_bytes=${body.length}`);
      return respond(key, step, body.length, key === "parent" ? childIds(body) : []);
    }
    return new Response("not found", { status: 404 });
  },
});
console.error(`fake-codex listening on http://127.0.0.1:${PORT}${FLAP > 0 ? ` (flap proxy -> :${HTTP_PORT}, cut=${CUT_BYTES}B)` : ""} steps=${STEPS} deltas=${DELTAS}x${DELTA_BYTES}B enc=${ENC_BYTES}B pace=${PACE_MS}ms/${PACE_EVERY}`);
