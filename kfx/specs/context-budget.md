# Context budget

Status: landed. Four levers against per-request token growth, ranked by measured savings. The 2026-08-29 session that motivated this (`~/.fx/sessions/1788017106042-*`, the one after the memory fixes) is the baseline throughout.

## Where the tokens went

Parent session, 20 minutes, `gpt-5.6-sol` on the Codex subscription:

| Turn | Model steps | Tool calls | Tool result bytes kept in the turn | Input per request | Turn input total |
| --- | ---: | ---: | ---: | --- | ---: |
| 1, architecture assessment | 29 | 100 | 650 KB | 22.8K to 161K tokens | 2.63M (89% cache read) |
| 5, "continue" | 20 | 82 | 378 KB | 27K to 108K | 1.35M |

Four one-off children ran 33 to 40 steps each with 0.76 to 1.0 MB of results; their usage never reached `usage-v2.json` or `~/.fx/usage.jsonl` (the ledger held the parent's 51 requests only). Estimated whole-process input: 25 to 30M tokens.

Three causes, in order of size:

1. Every model step resends the whole turn. fx kept every tool result verbatim until the turn returned; compaction existed only across turns (turn 5 started at 27K, so history projection already drops old results). Claude Code evicts old tool results in-turn (microcompact), Codex CLI runs its summary compaction inside the tool loop, Pi does neither but caps results at 50 KB.
2. The per-request prefix was 22.8K tokens: the skill catalog listed 76 skills from `~/.claude`, `~/.agents`, and `~/.codex` (37 KB, 9.2K tokens), the repo `AGENTS.md` (25 KB), and 16 tool schemas (45 KB, `terminal` alone 24 KB).
3. Each result was capped at 64 KB (`tool_result_limits.zig`), the loosest of the four harnesses (Codex 10 KB, Claude Code persists past about 30 KB with a 2 KB preview, Pi 50 KB), and the model batched five or six 300-line reads per step.

## Levers

| Priority | Lever | Enable | Effect |
| --- | --- | --- | --- |
| 1 | Evict old tool results from the request | `FX_KEEP_RECENT_RESULTS=N` | Results older than the newest `N` steps become a one-line stub with a `read_tool_result` handle. Eviction moves in batches of `N`, so the projected prefix changes once per `N` steps and the provider cache keeps hitting between batches; per-request result bytes stay below 2N steps' worth. Superseded 2026-09-01: the advance is now byte-threshold-triggered, see [threshold-eviction.md](threshold-eviction.md) |
| 2 | Child usage in the ledger | Automatic | Each child commit appends a `usage_checkpointed` event, so `usage-v2.json` and the session view carry the child's requests and tokens. Children inherit the parent's `FX_MAX_AGENT_STEPS` as before |
| 3 | Smaller results | `"max_tool_result_bytes": 16384` in `~/.fx/settings.json` (upstream key, minimum 1024) | Nothing to patch; the cap already applies to children in the same process |
| 4 | Smaller skill catalog | `FX_SKILL_SOURCES=claude` plus `--context-limit skill_description_bytes=512`; `disable-model-invocation: true` skills are always hidden | One projection (`modelVisibleSkills`) feeds the prompt catalog, the `skill` tool, and `skill_search`, so a hidden skill is neither listed nor loadable by the model; the `/skill` menu still shows everything. `fx doctor` fails on an unknown source name |

### Eviction projection

`src/core/agent/runtime/result_eviction.zig` keeps one `State` per turn, bound at the top of the step loop to the turn arena, the step budget, and `result_store.StorageTarget.fromSession(capability, dir)`; `state.view(overlay_arena, suffix)` runs right before `buildGatewayMessages` at both call sites. Step boundaries are assistant messages carrying tool calls. `evicted_before` (suffix index) and one stub string per evicted message live in the turn arena; the projected slice lives in the per-step overlay arena.

Stub: `<tool_result_handle>result-…txt</tool_result_handle>` followed by `read_file result (N bytes) cleared from the request to save context; use read_tool_result with this handle to read it again.`, the same handle tag `formatStoredResultOutput` already teaches the model. Results that were already stored (above the 16 KB `large_result_threshold_bytes`) reuse their handle; smaller ones are written at eviction time through `StorageTarget.store`, the path the tools use. A store failure degrades to a handle-less stub that tells the model to rerun the tool; it never fails the turn.

The canonical suffix is not touched, so recovery checkpoints, `read_tool_result`, resume, and the transcript all keep the full text.

### Not done, and why

- `terminal` schema (24 KB): the bytes are per-property descriptions inside the schema object, not one string, so a slimmer version means rewriting upstream `src/builtins/tools.zig`, the fork's first hot zone. An override file would only cover the top-level description. Left to upstream.
- Repo `AGENTS.md` (25 KB): it is this repository's own developer guide and the fork keeps upstream docs identical. A `project_doc_max_bytes`-style cap would truncate instructions, not save them.
- Rolling child usage into the parent ledger: the parent's `Usage` is not shared across threads and the child sessions now record their own; a rollup is a display concern for the parent's session view.
- A child-only step ceiling (`FX_SUBAGENT_MAX_STEPS`) was built and removed. fx ends a turn at the step limit as a failed turn with a notice (`orchestrator.zig`, `finishFailedTurnWithNotice("step_limit")`); there is no last-step nudge and no forced answer, so a child that finishes its reading on step 39 and would report on step 40 returns nothing. The 2026-08-29 children took 33 to 40 steps each; a cap of 30 loses all four reports. Neither Claude Code (opt-in `maxTurns` per agent definition, no default) nor Codex (`max_action_tokens`, a token budget) caps subagent steps by default. With eviction bounding the cost per step, the cap had no remaining job.
- A per-step aggregate cap across parallel calls: measure with `max_tool_result_bytes` first.
- Releasing a failed provider attempt before the retry backoff: see `turn-arena-memory-growth.md`, unchanged.

## Verification

Recorded in the FORK.md patch inventory entries; the reproductions use `kfx/repro` (`DUMP=1` writes every request body).

1. `zig build test` passes, including the new `result_eviction.zig`, `skill_contract.zig`, and `skill_runtime.zig` tests.
2. Fake Codex (`kfx/repro`, `DUMP=1 STEPS=12`), 20 KB fixtures read one per step, 8 KB encrypted reasoning per step:

   | Request | Unfiltered body | `FX_KEEP_RECENT_RESULTS=2` | Evicted outputs |
   | --- | ---: | ---: | ---: |
   | 4 | 136 KB | 136 KB | 0 |
   | 5 | 160 KB | 130 KB | 2 |
   | 9 | 253 KB | 165 KB | 6 |
   | 13 | 348 KB | 200 KB | 10 |

   The eviction run still drifts upward by about 8 KB per step: that is the encrypted reasoning item each assistant step carries, which stays in the request. The evicted stub's handle resolves to a 14,119-byte file under the session's `tool-results/` holding the text the model had seen.
3. Fake Codex with one child: a child session captured while alive carries a `usage_checkpointed` event and a `usage-v2.json` with its input tokens; before the patch both were empty.
4. Real skill roots on this machine, request captured through the fake endpoint with `FX_HOME` isolated: unfiltered 76 skills, 38,200 bytes; with the patch and no variable 63 skills (13 `disable-model-invocation` skills gone); `FX_SKILL_SOURCES=claude` 48 skills, 24,657 bytes, every location under `~/.claude/skills`. Instructions bytes for the request went from 65,698 to 53,276.

## Upstream

Eviction overlaps with upstream [PR #471](https://github.com/vercel-labs/fx/pull/471) (summary handoff at 80% of usable input, inside the turn). The two compose: eviction runs first and is cheap; #471 is the fallback when a turn still fills the window. When #471 lands, re-attach the projection ahead of its compaction check at the same `buildGatewayMessages` slot. The `disable-model-invocation` support and the child usage checkpoint are candidates for upstream on their own; the child usage gap is a plain bug.
