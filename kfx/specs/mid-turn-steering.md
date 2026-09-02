# Mid-Turn Steering

Fork spec for the `kfx` patch stack. Status: idea, not implemented. Nothing below exists in the tree.

Inject user messages typed during a running turn into that turn at the next step boundary, like pi and Amp, instead of queueing them for the next turn.

The seam exists: `drainPendingUserSuffix` in `src/core/agent/runtime/tool_batch.zig` already injects permission-approval feedback into `within_turn_suffix` at every step boundary; wiring the live prompt queue into that drain is the skeleton.

The hard part is semantics: early-consumed queued messages must stay consistent with queue review, cancel recovery, and session log turn attribution.
