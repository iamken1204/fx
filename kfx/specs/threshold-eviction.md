# Threshold-triggered result eviction

Status: removed on 2026-09-06, historical only. This document retains the 2026-09-01 measurements and retired design. See [the removal decision](../../FORK.md#removed-tool-result-eviction-historical-only). It is not an active feature or an implementation requirement.

The threshold patch is recorded in this rebased stack at `2e4f9eba65c1652b6cf4cf340d8d07643bed0f28`, still present at pre-removal HEAD `1574e82e10d568b362690fab3b270df3a329efde`. It replaced the batch advance described in [context-budget.md](context-budget.md) with a byte threshold. All commands and environment settings below apply to those old eviction-enabled versions and are ineffective after removal. The old comparisons are not measurements against upstream restoration baseline `e051437fe2c452b4af1a796ad5a7e20dd64fd45c`.

## Problem

Batch eviction trades cache for context. With `FX_KEEP_RECENT_RESULTS=4`, the eviction boundary advances once per 4 steps, and every advance changes the projected prefix, so the provider prompt cache falls back to the stable ~20K-token system prefix.

Measured on 2026-09-01, session `08b7ba7e` (real Codex, `gpt-5.6-sol`, 23 requests, 1.10M input):

| Request | Context (input delta) | Cache hit fell to | Fresh tokens paid |
| --- | ---: | ---: | ---: |
| 9 | 48,947 | 19,968 | 28,979 |
| 13 | 62,828 | 19,968 | 42,860 |
| 17 | 30,779 | 19,968 | 10,811 |
| 20, 21 | ~39,000 | 19,968 | ~19,000 each |

Overall cache hit was 77% (253K fresh of 1.10M). The same-prompt A/B on 2026-08-30 measured Claude Code at 92% and Pi at 88%; both leave the prefix untouched within a turn. Amp goes further, letting context grow to 90% of the 272K window before compacting, and runs fine on the same Codex subscription: resending cached tokens is cheap, changing the prefix is what costs. The eviction patch as landed pays that cost every `N` steps for a context ceiling the turn usually does not need.

## Historical design

The implementation kept the eviction machinery and changed when the boundary advanced.

- `FX_KEEP_RECENT_RESULTS=N` keeps its meaning: the newest `N` steps survive a sweep verbatim, and `0` disables eviction entirely.
- `FX_EVICT_THRESHOLD_KB=T` (new, default 256) sets the trigger: when the tool-result bytes in the un-evicted part of the suffix, excluding the newest `N` steps, reach `T` KiB, one sweep advances `evicted_before` past everything except those newest `N` steps.

Between sweeps the projected prefix is byte-identical, so the cache keeps hitting for as long as the threshold allows, the Amp property, while the sweep still bounds the request body the way the batch version did. 256 KiB of result bytes is roughly 65 to 85K tokens on top of the ~20K stable prefix, well inside the 272K window; a turn like today's (about 40 KB of results per step) sweeps once or twice instead of resetting the prefix four times.

Unchanged: stub format and `<tool_result_handle>` retrieval, `StorageTarget.store` on sweep, the canonical suffix, session log, checkpoints, resume, and both `state.view` call sites ahead of `buildGatewayMessages`.

## Historical verification

Run on 2026-09-01, all passing:

1. Unit tests in `result_eviction.zig`: no advance below the threshold regardless of step count; a sweep keeps exactly the newest `N` steps and stores handles; the projected prefix pointer-stable between sweeps; a second sweep after the threshold refills. `zig build test` green.
2. `cd kfx/repro && DUMP=1 STEPS=12 sh run.sh evict12t FX_KEEP_RECENT_RESULTS=2 FX_EVICT_THRESHOLD_KB=48`: requests 1 to 6 carry no stubs, request 7 stubs steps 1 to 4 in one sweep, the boundary holds through request 10, request 11 sweeps steps 5 to 8: two prefix resets in 13 requests where the batch version reset five times.
3. Real Codex endpoint, isolated HOME with copied credentials: a three-step `read_file` `fx ask` turn with `N=2`, `T=8` completed normally.

## Upstream

The old integration ran threshold eviction before the pressure check for upstream automatic compaction. This could delay compaction. The integration has been removed; upstream prompt assembly and automatic compaction run without it. Do not restore this projection when rebasing or implementing other context features.
