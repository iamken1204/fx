# Recoverable Session History Spec

Fork spec for the `kfx` patch stack. Status: not implemented. Nothing below exists in the tree.

Phase 2 of the context-retention roadmap. Keep canonical session history lossless and give the model bounded, read-only tools to locate and recover exact turns after those turns leave the prompt.

## Relationship and rollout order

Phase 1 is [context-retention.md](context-retention.md). It extends the directly visible history horizon and moves retained history into the cacheable prompt prefix. This spec owns what happens beyond that horizon.

The rollout order is:

1. Ship Phase 1 Patch A and Patch C together.
2. Add stable session-local history locators and exact bounded reads.
3. Add deterministic history search and omission landmarks.
4. Measure real long-session prompt use, retrieval success, and cache behavior.
5. Reconsider Phase 1 Patch B (`FX_HISTORY_BUDGET_DIVISOR`) only after those measurements.

This is a product rollout dependency, not a storage dependency. Phase 1 remains useful if Phase 2 is delayed. Phase 2 must also work with the upstream default history limit, but it does not replace Phase 1: recent turns stay directly visible, while older turns become recoverable on demand.

## Problem

The canonical session retains typed history after the model-context projection compacts it, and large tool results already remain available behind `read_tool_result` handles. The model has no corresponding way to navigate canonical conversation history.

Once a turn leaves the prompt, the model sees only a line-capped rule-based summary or a budget-trim notice. Neither representation identifies the omitted source turns. If an early constraint, exact value, failed approach, or tool provenance was not copied into the summary, it is effectively unreachable even though fx still has the canonical record.

Raising the turn limit delays this failure. It cannot remove it because every model has a finite context window, and sending all retained history eventually makes retrieval quality and request cost worse.

## Goal

Make prompt eviction reversible without treating historical text as current authority:

- canonical history remains the source of truth;
- omitted prompt spans carry compact navigation landmarks;
- the model can search for candidate turns and read exact neighboring turns;
- all retrieval output is bounded and enters the model as untrusted tool evidence;
- recent history still uses the direct, cacheable Phase 1 path.

The design follows the lossless-storage and query-time-projection direction described by Scroll in [Context as an Environment](https://arxiv.org/abs/2608.21690), but does not adopt its Python runtime or its full memory architecture.

## Scope

### Included

- Stable, opaque, session-local locators for canonical history turns.
- A read-only `search_session_history` tool for deterministic lexical lookup in the active session.
- A read-only `read_session_history` tool for exact bounded materialization around one locator.
- Recoverability metadata in turn-count compaction and token-budget trimming notices.
- Exact tool-result handles and file evidence already attached to recovered turns.
- Restart, recovery, log-compaction, stale-locator, malformed-locator, and allocation-failure tests.
- An explicit trust boundary preventing recovered historical user text from becoming current permission authority.

### Explicitly excluded

- Cross-session or profile-wide memory. The first version is bound to the active saved session.
- LLM-generated summaries, embeddings, vector databases, or an ingestion-time extraction model.
- A persistent Python, JavaScript, or shell kernel.
- Model-authored writes to canonical history or the history index.
- Automatic injection of search results before the model asks for them.
- Changes to the contents of the existing rule-based summary beyond recoverability metadata.
- A guarantee that the model will always search for the right evidence. The harness guarantees availability and bounded access, not retrieval judgment.
- Treating project files such as `AGENTS.md` or `~/.fx/SYSTEM.md` as session history. They remain stable-prefix context.

## Architecture decisions and invariants

### Ownership

- `src/core/session/` owns locator generation, canonical turn lookup, lexical matching, omission ranges, and storage/recovery invariants.
- `src/tools/session/` owns the two model-facing read-only tools.
- `src/core/tooling/` owns their centralized specs and dispatch wiring under the existing tool registry conventions.
- `src/core/agent/runtime/` may format recoverability notices, but it must not own canonical history or a second index.
- `src/main.zig` remains composition wiring only.

### Canonical history remains authoritative

`SessionRuntime.history` and its durable session representation remain the exact source records. The Phase 2 index is derived navigation data. It must be rebuildable from canonical history and must never replace, rewrite, or summarize a turn.

The implementation must not make `events.jsonl` byte offsets, `log_generation`, or sequence numbers part of the public locator contract. Session log compaction and state replacement can change physical event layout. A model-visible locator must continue to identify the same semantic turn after an ordinary save, restart, and log compaction.

If canonical history cannot be opened or validated, search and read fail closed. They must not return a stale sidecar entry as if it were authoritative.

### Stable locator contract

A locator is an opaque, versioned token scoped to the active session:

```text
HistoryLocator = h1:<ordinal>:<semantic-digest>
```

- `ordinal` is the zero-based position in canonical append order, not an event-log byte offset.
- `semantic-digest` is a bounded digest produced by one frozen `h1` canonicalization of the stable session identity, ordinal, and typed turn.
- The digest binds the locator to its session without exposing the session ID. It also covers the turn tag and all model-relevant durable fields, including user text, assistant text, tool calls, projected tool results or handles, background metadata, interruption state, and file evidence.
- The tool capability is bound to one active session and recomputes the digest with that session's stable identity. A locator from another session therefore fails with `HistoryLocatorMismatch`, even when both sessions contain identical text at the same ordinal.
- Full digest comparison happens before returning content. A shortened display form may appear in prose, but tools accept only the full token.
- Locator parsing has fixed byte and integer limits and never accepts paths, raw offsets, or caller-selected session IDs.

The implementation must add frozen digest test vectors. If the semantic schema later changes incompatibly, introduce `h2`; do not silently change what `h1` means.

A locator can become stale after explicit recovery rolls canonical history back past that ordinal or replaces the turn with different content. Staleness is reported explicitly. The tool must never fall through to the current turn at the same ordinal.

### Omission landmarks

Every automatic operation that removes exact turns from the prompt projection must describe the omitted canonical range without copying historical user text:

```text
HistoryOmission {
  first: HistoryLocator,
  last: HistoryLocator,
  turn_count: usize,
  reason: turn_limit | token_budget,
}
```

Turn-limit compaction normally produces one contiguous omission. Token-budget selection may produce more than one range. Adjacent omitted turns are coalesced; the notice carries at most eight ranges. If more ranges exist, it reports the total omitted count and the oldest/newest locators, then directs the model to `search_session_history`.

A landmark is navigation metadata, not a summary and not authority. It may be attached to the context projection or generated beside it, but it must not be written back as a duplicate canonical history turn.

The current budget selector may keep a small older turn after skipping a larger newer turn. The implementation must either preserve that behavior and emit multiple exact omission ranges, or deliberately change selection to a contiguous recent suffix with focused tests and a documented reason. It must not falsely describe a discontinuous omission as one exact range.

### Search contract

`search_session_history` searches only canonical turns in the active session.

```text
SearchSessionHistoryArgs {
  query: bounded non-empty UTF-8 text,
  limit: optional usize, default 10, maximum 20,
  before: optional HistoryLocator,
}

SearchSessionHistoryHit {
  locator: HistoryLocator,
  kind: assistant | background_command | interrupted,
  matched_fields: bounded list,
  user_preview: bounded text,
  assistant_preview: optional bounded text,
  tool_names: bounded list,
}
```

Rules:

- Search covers user and assistant text, tool names and arguments, stored result previews or handles, file-evidence paths, background metadata, and interruption metadata.
- Compacted summaries are projection artifacts and are not returned as source hits.
- Matching is deterministic and implemented without an LLM call. The first version uses literal substring matching: ASCII compares case-insensitively; other UTF-8 bytes compare exactly. More advanced ranking is a separate patch.
- Results are ordered newest first. `before` paginates toward older ordinals without exposing an unbounded offset.
- Search scans or reads canonical data under a fixed work and output budget. Hitting a scan limit returns a visible `incomplete` marker and continuation locator; it never reports partial coverage as complete.
- Each preview is capped, total output is capped, and full turn contents require `read_session_history`.
- An empty or whitespace-only query is rejected. Positional navigation uses omission landmarks and exact reads, not an accidental list-all search.

A derived on-disk index may be added only if measurements show that bounded canonical scanning is too slow. Such an index must be versioned, disposable, atomically replaced, and validated against canonical history before use. SQLite, FTS, and new dependencies are not part of the first patch.

### Exact read contract

`read_session_history` materializes one exact turn plus a small neighboring window:

```text
ReadSessionHistoryArgs {
  locator: HistoryLocator,
  before: optional usize, default 0, maximum 8,
  after: optional usize, default 0, maximum 8,
  max_bytes: optional usize, default 8192, maximum 65536,
}
```

The result preserves canonical order and includes each returned turn's full locator, typed role/kind boundaries, exact user and assistant text, tool calls, bounded stored result representation, status, and file evidence. Existing large-result handles remain handles; this tool does not inline their payloads or bypass `read_tool_result` limits.

If the byte cap cuts the requested window, the result reports which locators were returned and the next unread locator. It truncates only at UTF-8-safe field boundaries and clearly marks omitted bytes. It never emits malformed JSON or silently clips a value that appears complete.

The neighboring window is clamped to canonical history bounds. A stale or mismatched anchor returns no neighboring turns.

### Trust and permission boundary

Recovered history is evidence, not a new user instruction. This remains true when the recovered record has role `user` or contains imperative text.

- Both tools return ordinary current-turn tool results with explicit untrusted-history framing.
- Recovered content must not enter `root_user_messages`, permission-review authority, configured approval rules, or saved-session approval rules.
- Historical requests cannot authorize a command, network access, external path, publication, or any other sensitive action in the current turn.
- The permission reviewer may receive a bounded excerpt under the existing earlier-tool-result evidence rules, but the excerpt remains untrusted evidence and never authority.
- Search arguments and recovered text are escaped as data. They cannot inject system messages or create a second system prefix.
- The tools are read-only and must use the active session capability rather than accepting an arbitrary filesystem path or session directory.

Add a regression in which an old user turn says to allow a sensitive command and a later history read retrieves it. The pending command must still follow current permission policy.

### Prompt and cache behavior

Phase 1 owns the stable-prefix, durable-history, overlay, current-message, and within-turn-suffix order. Phase 2 does not introduce a second prompt assembly path.

Omission landmarks are deterministic for an unchanged canonical history projection. Search and read observations occur only after the model calls the tools, inside the current turn's non-cacheable suffix. They must not mutate the cacheable durable-history bytes on later steps of that same turn.

No history search runs implicitly during prompt construction. This keeps first-call latency and cache behavior predictable.

## Patch sequence

### Patch D: stable locator and exact read

1. Define the versioned locator and frozen semantic digest in `src/core/session/`.
2. Thread canonical ordinal information into the model-context projection without changing canonical turn ownership.
3. Add omission metadata for turn-limit and token-budget projection.
4. Add `read_session_history` with active-session capability binding and bounded output.
5. Prove locator stability across save, resume, and session-log compaction.

Patch D is useful by itself: the model can follow a landmark to exact source turns even before lexical search exists.

### Patch E: deterministic search

1. Add bounded canonical scanning and literal matching.
2. Add `search_session_history` and pagination.
3. Return locators and previews only; exact content remains owned by Patch D.
4. Measure scan latency and memory on long saved sessions before considering a derived index.

### Patch F: retrieval guidance and tuning

1. Add concise tool guidance telling the model when a compaction or budget notice means exact history is available.
2. Exercise retrieval in long-session E2E scenarios, including evidence with unknown wording where the omission landmark supplies the starting point.
3. Measure retrieval calls, prompt input, cache reuse, missed evidence, and latency.
4. Decide whether Phase 1 Patch B still provides enough value to justify a larger directly visible history budget.

Each patch is independently keepable or droppable during an upstream rebase and gets its own `FORK.md` inventory row when implemented.

## Failure behavior

- Unsaved or ephemeral session with no canonical capability: return `session history is unavailable` without searching process memory through a second path.
- Invalid locator syntax: return `InvalidHistoryLocator`.
- Valid locator from another session or changed content at the ordinal: return `HistoryLocatorMismatch`.
- Ordinal removed by recovery rollback: return `StaleHistoryLocator`.
- Canonical state unavailable or invalid: return a storage error and no hits.
- Work or output budget reached: return bounded partial results with an explicit continuation marker.
- Existing tool-result handle missing or corrupt: return the canonical handle and its unavailable status; do not fabricate payload content.

Errors must be useful to the model without exposing profile paths, session directories, raw event-log offsets, or unrelated session IDs.

## What this does not solve

The model can still fail to search, choose weak query terms, sample the wrong region, or stop before enough evidence is collected. Scroll reports the same class of failure even with lossless storage and a programmable retrieval environment. Omission landmarks reduce dependence on remembered wording, but they do not remove model judgment from retrieval.

Long-lived operating rules still belong in `~/.fx/SYSTEM.md`, `AGENTS.md`, or another stable-prefix source. Recoverable history is for exact episodic evidence, not a replacement for durable policy.

## Verification

1. Focused locator tests prove frozen `h1` vectors, malformed-input rejection, cross-session mismatch, rollback staleness, and exact semantic verification.
2. Save and resume a session, force session-log compaction or state replacement, and confirm every preexisting locator still resolves to byte-identical typed turn content.
3. Run beyond `FX_MAX_HISTORY_TURNS`: the prompt projection contains bounded omission landmarks, and an omitted early turn is recoverable verbatim with `read_session_history`.
4. Force token-budget trimming with discontinuous selections and confirm every omitted turn belongs to exactly one reported range, or confirm the deliberately changed contiguous-suffix policy.
5. Search ASCII, mixed-case ASCII, CJK text, tool names, arguments, result handles, and file paths. Verify deterministic ordering, pagination, scan-limit reporting, and output caps.
6. Recover a turn containing a large tool-result handle, then resolve it through `read_tool_result`; `read_session_history` itself never exceeds its cap.
7. Capture a multi-step gateway request. Search/read results appear only in the current non-cacheable suffix, while the Phase 1 stable prefix and durable-history bytes remain unchanged.
8. Retrieve an old user instruction that asks for a sensitive action. Confirm it does not satisfy permission authority and the action still receives the normal current-turn policy decision.
9. Run focused Zig tests, focused E2E, `zig fmt --check src/`, and `zig build`.
10. Exercise the path with freshly built `./zig-out/bin/fx` against a deterministic fake gateway: cross the history horizon, follow a landmark, search, read an exact turn, and use it in the answer. Confirm no abort and clean stderr.
11. After implementation is committed and pushed on a feature branch, require Full CI and the final ship gate for that exact commit before marking the PR ready.

Any new root `tests/e2e/*.test.ts` owner must receive exactly one classification in `scripts/pgso/corpus.json`.

## Documentation follow-through

When implemented:

- add both tool specs to the centralized built-in tool help surface;
- document that recovery is active-session-only and read-only;
- distinguish directly retained history from recoverable history in `README.md`;
- add Patch D, E, and F rows to the `FORK.md` patch inventory as they land;
- remove this spec only after all required patches land, per the fork spec lifecycle.

## Conflict policy notes for the patch inventory

- Patch D: preserve the opaque semantic locator and canonical-source verification. If upstream adds stable turn IDs, drop the digest locator and adapt the tools to upstream IDs rather than maintaining two identities.
- Patch E: keep search read-only, deterministic, bounded, and active-session-scoped. If upstream adds history search, map the tool contract onto it and delete the duplicate scanner.
- Patch F: keep retrieval observations after the cacheable history boundary. If upstream changes prompt assembly, reuse its single non-cacheable within-turn slot rather than adding another overlay.
