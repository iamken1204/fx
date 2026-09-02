# Local Web Control Plane

Fork spec for the `kfx` patch stack. Status: spec, ready to implement with `/fairway`. Nothing below exists in the tree.

## Intent

Add a single-user, local-first web control plane that can:

1. list every durable session under `~/.fx/sessions`, across workspaces;
2. show a session's persisted transcript and current execution state;
3. continue a dormant session from the browser;
4. send the next prompt, queue a follow-up, or cancel work in a session already owned by a running local kfx process; and
5. update the browser incrementally without polling whole transcripts.

The happy path should read as: start `kfx web`, open the loopback URL, choose a session, read it, send a prompt, and watch the result stream.

## Product boundary

The first version is a conversation control plane, not a browser terminal emulator.

It renders structured transcript events, tool activity, permission state, usage, and session status. It does not mirror the TUI grid, forward arbitrary keystrokes, take the hosted-terminal write lease, or expose shell PTYs in the browser. Those capabilities have different authority, resize, escape-sequence, and recovery contracts and should be a later spec if the conversation UI proves insufficient.

No user or team authentication is required. The server must bind to `127.0.0.1` and `::1` only, choose a random available port by default, print the exact URL, and reject non-loopback Host and Origin values. Remote access, LAN binding, TLS, accounts, sharing, and cloud persistence are out of scope.

## Architectural decision

Implement this in kfx as an additive local control plane. Do not build the first version by extending `../pi-tower`.

pi-tower is useful prior art for a small HTTP/WebSocket relay and static UI, but its ownership model is wrong for this feature:

- it only knows ACP children that it spawned, not the complete durable catalog in `~/.fx/sessions`;
- its session map is process memory, so it does not make the local durable store authoritative;
- an ACP child cannot acquire a session already locked by another TUI or ACP process;
- it proxies runner/ACP transport rather than defining kfx session-control semantics; and
- its remote runner, token, Node, and `ws` concerns add a second runtime and dependency surface to a thin upstream patch stack.

Reusable ideas are limited to its event-driven UI shape and reconnect behavior. Do not import pi-tower modules or make kfx depend on its checkout. A future remote relay may consume the same protocol after the local contract is stable.

## Ownership

Keep the composition root thin.

- `src/core/session/` owns durable catalog and read-only transcript snapshots.
- A new `src/core/control/` deep module owns control-plane contracts, live-process registration, routing, command admission, event replay, and the loopback server.
- `src/core/app/` exposes a narrow adapter from the live app runtime to the control module. It remains the only owner that may mutate a running conversation.
- `src/ui/` remains terminal rendering only and does not own web state.
- `src/acp/` remains an external protocol adapter. Reuse session primitives beneath ACP rather than driving ACP internally.
- `src/main.zig` and CLI dispatch only compose `kfx web` and the live-session adapter.

Static browser assets should be checked-in files owned by the control module and embedded at build time. Avoid a JavaScript build step and new package manager dependency. Plain HTML, CSS, and browser JavaScript are sufficient for the first version.

## Typed contract

Use one domain model for HTTP snapshots, the event stream, and process-local control. JSON is an encoding, not the domain boundary.

```text
SessionSummary
  id
  title
  workspace_root
  created_at_ms
  updated_at_ms
  presence: dormant | active
  phase: idle | running | waiting_permission | failed
  owner: null | { process_id, endpoint_generation }
  last_event_cursor

SessionSnapshot
  summary
  transcript
  usage
  pending_input
  capabilities

SessionCommand
  submit_prompt { text }
  queue_follow_up { text }
  cancel

SessionEvent
  cursor
  session_id
  kind
  payload
```

Refine field names against existing session codec types during implementation; do not duplicate durable transcript or usage models when an existing type can be projected safely.

Every mutating command carries a caller-generated `command_id`. Admission is idempotent per session, and responses distinguish `accepted`, `already_applied`, `conflict`, `not_available`, and `invalid`. Commands target the stable session ID, never a PID or socket path.

`capabilities` is authoritative for the selected session and phase. The UI must hide or disable actions not admitted by the backend rather than infer state from transcript text.

## Session ownership and routing

The durable session lock remains authoritative: exactly one process mutates a session.

### Dormant session

When no live owner is registered, the web process opens the session through the normal writable resume path, becomes its owner for the duration of the turn, runs the prompt, persists events, and releases ownership when idle. It must not bypass `SessionBusy` or edit session files directly.

The first implementation may support one concurrently running dormant session inside `kfx web`. If so, encode that limit in admission and UI capabilities instead of silently serializing unrelated requests. Generalize only after measurements justify it.

### Active session

Each saved interactive or ACP process publishes a private, process-local control endpoint inside its session directory after it acquires the durable lock. On Unix this is a Unix domain socket plus a small metadata record containing protocol version, PID, process start identity, and endpoint generation. File and directory permissions remain private (`0700` directories, `0600` metadata/socket where applicable).

The web process treats registration as a hint, then proves liveness by connecting and completing a versioned handshake. Stale metadata is ignored and removed only after the durable lock and process identity prove that no live owner can use it. PID existence alone is insufficient because PIDs are reused.

Commands for an active session go to its owning process. That process admits them onto its existing input/cancel path and emits events after persistence. The web process never writes around the owner.

Initial active-session semantics:

- idle owner: `submit_prompt` starts the next turn;
- running owner: `queue_follow_up` uses the existing next-turn queue;
- running owner: `cancel` uses the existing cancellation path;
- permission or interactive question pending: expose state read-only in v1 unless an existing typed answer contract can be reused without synthesizing TTY input;
- mid-turn steering remains governed by `mid-turn-steering.md`; this feature must not accidentally consume queued input at step boundaries before that spec lands.

### Transcript and event ordering

Persisted session data is the source of truth. Live events are an acceleration layer.

On attach or reconnect, the browser requests a `SessionSnapshot` and receives its `last_event_cursor`, then subscribes from that cursor. The server returns replayable events from a bounded ring. If the cursor has expired, it instructs the client to reload a snapshot. UI reducers must tolerate duplicate events by cursor.

Do not stream raw terminal bytes or reconstruct truth from stdout. Emit structured events at existing session-log and runtime boundaries.

## Local web protocol

Expose a small versioned API under `/api/v1`:

- `GET /sessions`: paginated global session summaries;
- `GET /sessions/{id}`: snapshot;
- `POST /sessions/{id}/commands`: one typed, idempotent command;
- `GET /events?cursor=...`: event stream for catalog and selected-session changes;
- `GET /` and static assets: embedded UI.

Prefer Server-Sent Events for v1 because browser-to-server traffic is ordinary request/response and server-to-browser traffic is one-way structured updates. Use WebSocket only if implementation evidence shows SSE cannot satisfy cancellation, reconnect, and transcript streaming.

Apply explicit body, header, transcript page, event payload, and connection limits. Never expose arbitrary filesystem reads, command execution, tool invocation, or control-socket paths through the API.

## UI scope

The first UI has three regions:

1. a searchable session list grouped or filterable by workspace, showing active/dormant and phase;
2. a transcript reader with incremental assistant text and structured tool rows; and
3. a composer whose actions come from backend capabilities.

Required states: loading, empty catalog, dormant, active-idle, active-running, queued input, cancelled, waiting for permission, stale owner, reconnecting, and error. Preserve the selected session and draft across event-stream reconnects. No settings editor, filesystem browser, terminal canvas, multi-user presence, or pi-tower runner topology in v1.

## Delivery slices

Each slice is one keepable fork intent and should be implemented with `/fairway`, keeping orchestration happy-path-first and pushing details into deep modules.

### Slice 1: read-only tower

- add `kfx web` and loopback server;
- project the global durable catalog into `SessionSummary`;
- serve session snapshots and the embedded read-only UI;
- add bounded pagination and transcript loading;
- exercise the built binary by opening the page and inspecting a real saved session.

This slice delivers immediate value and validates the UI/data contract without changing live runtime ownership.

### Slice 2: dormant continuation

- admit `submit_prompt` for dormant sessions through normal writable resume;
- stream persisted/runtime events to the browser;
- add cancel and idempotent command handling;
- prove lock conflicts are reported rather than bypassed.

### Slice 3: active-process bridge

- publish and clean up the private process-local endpoint;
- route idle submit, running follow-up queue, and cancel to the owning runtime;
- add stale-owner recovery and event cursor replay;
- cover simultaneous TUI and browser interaction.

### Slice 4: optional remote relay

Only after the local contract is stable, decide whether pi-tower should become a separate remote relay that speaks the versioned control protocol. It must not become the canonical session store or require kfx to import Node dependencies.

## Tests and operational proof

Unit tests belong beside the control contracts and routing logic. Add deterministic tests for:

- global catalog projection across multiple workspaces;
- pagination and bounded transcript snapshots;
- command idempotency and phase-based admission;
- dormant ownership acquisition and `SessionBusy` conflict;
- live endpoint handshake, stale metadata, PID reuse defense, and cleanup;
- event cursor replay, duplicate delivery, and expired cursor fallback;
- loopback Host/Origin enforcement and request-size limits; and
- queue/cancel behavior without changing mid-turn steering semantics.

Add one root `tests/e2e/*.test.ts` owner for browser-independent HTTP/SSE behavior and classify it exactly once in `scripts/pgso/corpus.json`. UI behavior that needs a browser should use the smallest available browser harness without making the Zig binary depend on it.

Before declaring any slice ready:

1. run `zig fmt --check src/`;
2. run focused Zig and E2E tests;
3. run `zig build`;
4. launch the freshly built `./zig-out/bin/fx web`;
5. exercise the slice's real happy path against a saved session and confirm clean stderr/process shutdown; and
6. after an explicit commit/push/PR request, require Full CI and the ship gate for the exact commit per `AGENTS.md`.

## Documentation and fork maintenance

When Slice 1 lands, document `kfx web` in this fork's feature table and command help. Add each landed slice to the `FORK.md` patch inventory, with the conflict policy below, then delete this spec only when all intended slices have landed or split remaining work into a new spec.

Conflict policy:

- prefer new `src/core/control/` files and narrow adapters over edits to upstream session internals;
- reuse upstream session catalog, codec, lock, event log, cancellation, and input queue contracts;
- if upstream adds a daemon or web UI, port this protocol onto its seam and drop redundant server code;
- never weaken the session lock or permission system to keep the browser working; and
- keep pi-tower optional and outside the kfx build graph.

## Open decisions for implementation

These should be resolved from code evidence during Slice 1, not by adding speculative abstraction now:

- whether the embedded static files should be generated as Zig byte imports or served from a small checked-in asset directory;
- whether existing transcript snapshots are bounded enough for the initial API or need a dedicated page cursor;
- whether SSE can reuse an existing event fan-out primitive; and
- whether `kfx web` may own one or several dormant running sessions concurrently.
