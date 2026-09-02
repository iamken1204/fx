# Context Retention Spec

Fork spec for the `kfx` patch stack. Status: not implemented. Nothing below exists in the tree.

Deepen conversation memory without adopting LLM summarization: raise the hardcoded 8-turn compaction ceiling behind an environment seam, and reorder the prompt so durable history joins the cacheable prefix. Two patches, one optional tuning seam.

## Relationship to recoverable history

This spec is Phase 1 of the context-retention roadmap. It keeps more recent history verbatim and makes that history cacheable.

Phase 2 is [recoverable-session-history.md](recoverable-session-history.md). It gives the model bounded, read-only access to exact canonical turns after those turns leave the prompt. Phase 2 complements rather than blocks this spec: Patch A and Patch C ship first, then Phase 2 adds stable locators, exact reads, search, and omission landmarks.

Phase 1 remains useful on its own, and Phase 2 must not replace the direct recent-history path. Patch B stays optional and should be reconsidered only after Phase 2 measurements show whether a larger prompt-resident history budget is still worthwhile.

## Problem

fx folds history into a rule-based summary after 8 turns, and the history it does keep is never prompt-cached.

1. `max_history_turns = 8` is a constant in `src/main.zig` (line 191). No env var, config key, or flag changes it. Once the model-context projection exceeds 8 items, `compactHistory` (`src/core/session/session.zig` line 3023) folds older turns into one `compacted_summary`, keeping the newest 4 (`preservedRecentTurnCount`, line 3547). The summary is line-capped rule extraction and deliberately excludes root user request text, so early constraints and decisions vanish from the model's view by the ninth turn.
2. History is resent uncached on every request. `buildGatewayMessages` (`src/core/agent/runtime/prompt_context.zig` lines 37 to 41) places the per-step ephemeral overlay between the stable prefix and durable history. The overlay is marked `no_cache`, and `writeChatMessagesJson` (`src/gateway/vercel_protocol.zig` line 356) stops marking anything cacheable after the first `no_cache` message. The cacheable region therefore ends at the stable system prefix; history never enters it.

Fix 1 alone raises resend cost linearly. Fix 2 alone caches only 8 turns. They ship together.

## Goal

Keep verbatim history until token pressure, not turn count, forces folding. Make the kept history part of the cacheable prompt prefix so the deeper history is cheap to resend.

## Non-goals

- LLM-generated summaries. That requires an async model call inside the turn loop and touches `session.zig`, the orchestrator, and the gateway at once, which breaks the thin-patch strategy. The rule-based summary stays as the beyond-horizon fallback. Revisit only if long sessions still hurt after these patches.
- A settings.json key. Fork seams are env vars, per FORK.md.
- Changing what the summary contains. The permission reviewer depends on summaries never carrying user-authority text (`root_user_messages_complete = false`); do not touch that.

## Patch A: `FX_MAX_HISTORY_TURNS`

Read the env var once via `io_mod.getenv` where the constant lives in `src/main.zig`. Parse as `usize`. Unset or invalid keeps the upstream default of 8. `0` disables turn-count folding entirely; `compactHistory` already treats 0 as a no-op (session.zig line 3024).

Wiring audit at implementation time:

- The live TUI, `fx ask`, and ACP paths all receive the value from the `main.zig` constant through `cli_surface` config and `SessionRuntime.initWithProviders`. The seam at the constant covers them.
- The subagent host owner has its own field default of 8 (`src/core/subagent/execution.zig` line 1393). Audited: `ownerValue()` in `src/core/subagent/tool_host.zig` (line 334) constructs the Owner without setting the field, so subagent children never see the configured value. The patch must read the same seam there.
- Struct-field defaults of 8 (and one of 4) in `tool_runtime.zig`, `app_agent_runtime.zig`, `app_session_runtime.zig`, and `acp/prompt.zig` are construction fallbacks, mostly test-only. Leave them unless the audit shows one on a live path.

Recommended fork value: `FX_MAX_HISTORY_TURNS=64`. Large but finite, so the far tail still folds into the rule-based summary instead of relying only on the budget drop below.

Safety net, unchanged: `appendHistoryChatMessagesBudgeted` (session.zig line 2537) already walks history newest-first and drops turns beyond a token budget of `(context_window - max_output_tokens) / 4`, injecting a system notice for what it dropped. A raised turn cap cannot blow the window; worst case is budget-trimmed history with a notice. Per-turn size is already bounded by the preview-plus-handle store (results over 16 KiB become a 4 KiB preview), so 64 turns is roughly 40k to 100k estimated tokens. The high end exceeds the roughly 42k to 50k budget of a 200k-window model; the excess degrades to budget-trimmed history with a notice, it does not blow the window.

## Patch B (optional): `FX_HISTORY_BUDGET_DIVISOR`

`history_context_budget_window_divisor = 4` in `src/core/agent/runtime/config.zig` (line 15) caps history at a quarter of the available window. An env seam allowing 2 doubles history depth. Only worthwhile after Patch C lands, since it doubles the resent bytes otherwise. Defer the decision until Phase 2 measurements in [recoverable-session-history.md](recoverable-session-history.md) show whether a larger prompt-resident history budget still improves outcomes. Ship last, or not at all.

## Patch C: cacheable history

Reorder `buildGatewayMessages` (`prompt_context.zig`) from

```
stable prefix, overlay, history, current, suffix
```

to

```
stable prefix, history, overlay, current, suffix
```

Consequences and required follow-through:

- `prefix_cacheable` in `vercel_protocol.zig` now survives through history, so history messages become eligible for cache markers.
- System-prefix invariant, in-tree and deliberate: the test `buildGatewayMessages preserves one system prefix for projected session history` (prompt_context.zig line 162) rejects any system message after the first user or assistant message, and history projection maps a mid-history compacted summary to user role for exactly this reason (a leading summary stays system). Moving the system-role overlay after history violates the invariant and fails that test. Resolve it one of two ways: re-role the moved overlay to user, mirroring how mid-history summaries are projected, or prove with captured POST bodies that both the gateway role-per-message format and the codex transport accept a post-history system message, then update the invariant test deliberately. Do not just delete the assertion.
- `findCacheBreakpoint` (vercel_protocol.zig line 770) picks the last user or assistant message before the final one. That lands on the history tail only on the first step of a turn, when the within-turn suffix is empty. On every later step the suffix holds the current turn's assistant messages, the walk stops inside the suffix where `prefix_cacheable` is already false, and no history message receives a marker, so marker-based caching covers only the stable prefix on precisely the steps that resend history most. Required adjustment, not just verification: anchor the breakpoint at the last cacheable user or assistant message before the first `no_cache` message. Capture both a first-step and a mid-turn request to confirm.
- Update the ordering test `buildGatewayMessages orders transient overlay before history and current prompt` (prompt_context.zig line 130), the invariant test above, and any `shouldCacheMessage` tests that assume the old order or the old breakpoint anchor.
- Semantics: the overlay is a per-step refresh of env and background state. Moving it after history places it closer to the current message, which if anything helps recency. Content is unchanged.
- Cross-reference: the multi-brain spec ([multi-brain-arch.md](multi-brain-arch.md), prompt cache boundary section) requires the same post-history overlay position for its merge slot. Whichever patch lands first owns the reorder; the other reuses the slot.

## What this does not fix

Sessions that exceed the raised cap or the token budget still degrade to the rule-based summary, which keeps a few line-capped items and no user request text. Recovering those exact omitted turns is owned by Phase 2, [recoverable-session-history.md](recoverable-session-history.md), not this spec.

Long-lived operating rules still belong in the stable prefix: `~/.fx/SYSTEM.md` (fork feature) and `AGENTS.md`, which no compaction touches. Recoverable history is episodic evidence, not a replacement for durable policy. Until Phase 2 lands, exact omitted turns remain unavailable to the model. Manual `/compact` at task boundaries remains available.

## Verification

1. `zig build test`.
2. Point `FX_GATEWAY_CHAT_URL` at a capture server (same setup as the FX_EXCLUDE_TOOLS check in FORK.md). Compare POST bodies with and without the seams: message order matches the new layout, cache markers appear on the stable prefix and the history breakpoint, and nothing after the overlay carries one. Capture a multi-step turn and confirm the second step still carries a history breakpoint marker and that stable-prefix and history bytes are identical to the first step's request.
3. Run a session past 8 turns with `FX_MAX_HISTORY_TURNS=64`: no `compacted_summary` appears in the projection, and turn 3 content is still quotable verbatim by the model at turn 12.
4. Run a session past the configured cap: the rule-based summary appears and large-result handles inside it still resolve through `read_tool_result`.
5. Rebase hygiene: one intent per commit (Patch A, Patch C, then B if ever), each with a conflict policy in the body, and rows added to the FORK.md patch inventory.

## Conflict policy notes for the patch inventory

- Patch A: keep the env read at the single definition site of the constant; if upstream makes the value configurable, drop the patch and map the env var onto upstream's mechanism.
- Patch C: the reorder is one call-site change in `prompt_context.zig` plus a breakpoint-anchor change in `vercel_protocol.zig` and test updates; `src/gateway/` is a FORK.md hot zone, so expect conflicts there. If upstream reshapes prompt assembly, re-apply the order at the new assembly point and re-verify the cache breakpoint on first-step and mid-turn captures.
