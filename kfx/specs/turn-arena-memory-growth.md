# Turn-arena memory growth

Incident report and fix plan for the `fix-turn-arena-tool-retention` patch. Status: the tool-call, recovery-checkpoint, provider-attempt, and subagent inspect-wait retention paths are fixed on the branch and verified with the reproductions below. The 2026-08-29 incident ran the earlier binary and reached 48,617 MiB of logical compressed memory before macOS killed it.

## Conclusions

1. macOS killed `kfx`, PID 70716, in a no-paging-space action. This was not a Zig panic or an application-requested exit.
2. The running binary was revision `c238ac38c465`, which contains `5a314dba` and its follow-up `c238ac38`. An old installed binary is not an explanation.
3. The existing patch fixes the two retention classes it names: per-tool scratch and cumulative recovery-checkpoint copies. The ordinary and parallel tool paths both use short-lived, C-allocator-backed call arenas.
4. The branch retained provider-attempt allocations in the turn arena. Request serialization, HTTP client state, provider-state replay parsing, and SSE event parsing all received the turn allocator. Their `free` and `deinit` calls cannot reclaim arena allocations before the turn ends. Fixed by an attempt-scoped arena with copy-out.
5. A parent waiting on children with `subagent inspect` plus a wait condition polled the child graph ten times a second into the tool call's arena. This path, not the provider attempt, produced the incident's magnitude: a real three-subagent session on the attempt-arena build reached 57 GiB, and the incident parent's last durable state was this wait. Fixed by a poll-scoped arena.
6. Three one-off subagents ran as threads inside the parent process. Their long turns therefore accumulated in the same PID. The parent and children had performed about 100 model attempts when the process died.
7. Codex quota exhaustion is correlated with this workload. It is more likely a consequence of the request volume than the trigger for the kill. A 429 would add retries and worsen both memory and token usage, but the durable incident record contains no `rate_limited` checkpoint or quota diagnostic.
8. The allocator bugs do not enlarge the context window by themselves. The same long tool turns do amplify cumulative context usage because every model step resends the growing turn. Fixing allocation ownership will fix memory growth, not the repeated-token cost.

## Incident identity

The parent session is:

```text
~/.fx/sessions/1787978797558-1787978797558304000-c0642d40a6fc5ebc
```

It started at 12:46:37 local time. The installed executable was `/Users/kettan/.local/bin/kfx`. `kfx status` reported:

```json
{"build_revision":"c238ac38c465"}
```

Revision `c238ac38` contains these two patches:

```text
5a314dba Reclaim tool-call and checkpoint scratch instead of retaining it in the turn arena
c238ac38 Keep the MCP input-required error code static past the dispatch copy-out
```

The installed binary modification time was later than both commits. The incident did not run a stale pre-fix build.

## Kernel evidence

The macOS unified log records this sequence:

```text
2026-08-29 13:07:51.325 apfs: disk3s5 kfx: ENOSPC
2026-08-29 13:07:58.451 memorystatus: triggering no paging space action
2026-08-29 13:07:58.451 memorystatus: killing largest compressed process kfx [70716] 48617 MB
```

The kernel first killed many idle daemons, then selected `kfx` as the largest compressed process. No `kfx` crash report exists under `~/Library/Logs/DiagnosticReports`.

The printed 48,617 MiB is not RSS and is not the physical size of the compressed payload. XNU obtains `get_task_compressed(proc_task(p))`, stores it as the selected process's compressed size, divides it by 1,048,576, and prints it as MB. The ledger is the logical uncompressed size of internal pages attributed to that task and held by the compressor:

- `bsd/kern/kern_proc.c`, `proc_pcontrol_filter` and `no_paging_space_action`: [XNU source](https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/bsd/kern/kern_proc.c#L4845-L4951)
- `osfmk/kern/task.c`, `internal_compressed` ledger definition: [XNU source](https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/osfmk/kern/task.c#L1222-L1242)

The number nevertheless proves that the task had touched and retained tens of GiB of logical pages. Disk exhaustion did not create those allocations. It removed paging headroom and determined when macOS killed the process. During the investigation the data volume still had only about 1.4 to 1.7 GiB free and swap remained heavily used.

## Session topology and load

The parent issued three one-off `subagent` create operations at 13:03:15:

| Session | Name | Completed model/tool steps | Tool calls | Final durable state before kill |
| --- | --- | ---: | ---: | --- |
| `1787978797558-...-c0642d40a6fc5ebc` | parent | 12 | 90 | waiting for one-off children |
| `1787979795796-...-9f07d2ff9717261f` | `remote-storage-path` | 34 | 110 | current turn still active |
| `1787979795801-...-43fc29a7190d2e75` | `remote-control-path` | 30 | 152 | current turn still active |
| `1787979795806-...-1830f5258f40e47d` | `remote-security-critic` | 24 | 108 | committed at 13:07:22 |

The three child sessions attempted to create three grandchildren each. Those nine calls were rejected with `invalid_state`; no grandchildren ran.

Subagent children are not separate OS processes. `Owner.start` launches `slotMain` with `std.Thread.spawn` in `src/core/subagent/execution.zig:1407-1441`, and `slotMain` runs the child loop in the same process at `src/core/subagent/execution.zig:3038-3074`. The three child turn arenas, their HTTP clients, and the parent turn arena were therefore all charged to PID 70716.

The completed checkpoints understate live work by one model attempt per active turn. Including the response that created the children, final-answer attempts, and the two streams active at the kill, the process had made about 100 model attempts across the four current turns. Unified network logs show overlapping Codex connections from PID 70716 through the kill.

The durable files are much smaller than the compressed footprint:

| Session | Event log | Latest checkpoint projection |
| --- | ---: | ---: |
| parent | 12.98 MB | 0.48 MB for the interrupted turn |
| storage child | 11.55 MB | 0.65 MB |
| control child | 13.78 MB | 0.75 MB |
| security child | 10.39 MB | 0.76 MB |

These files rule out retained semantic tool results as a direct 48 GiB explanation. They do not measure transient allocator pages created while serializing, parsing, and copying those values.

## What `5a314dba` fixed

Before the patch, every ordinary tool received the turn arena as its dispatch allocator. A nested arena backed by another arena cannot reclaim memory when it is deinitialized, so repository-wide grep output, scanned file content, read-file scratch, sanitization copies, and masked copies accumulated until the turn returned.

The patch gives every ordinary call a C-allocator-backed arena and copies only survivors to the result allocator:

- Sequential ownership boundary: `src/core/agent/runtime/orchestrator.zig:6578-6588`
- Dispatch receives distinct `call_allocator` and `result_allocator`: `src/core/agent/runtime/orchestrator.zig:7113-7138`
- Parallel worker arenas: `src/core/agent/runtime/parallel_execution.zig:139-175`
- Parallel per-call boundary: `src/core/agent/runtime/parallel_execution.zig:247-267`

The patch also moves recovery-checkpoint construction into local scratch. `buildExecutionMemory` deep-copies every tool result accumulated so far. Building that copy in the turn arena once or twice per model step retained a cumulative series of snapshots and produced quadratic growth. It now uses a C-allocator-backed scratch arena at `src/core/agent/runtime/orchestrator.zig:2026-2083`; the session sink serializes or duplicates the checkpoint before that scratch arena disappears.

The offline repository-grep reproduction measured the intended improvement:

| Run | Steps | Peak RSS |
| --- | ---: | ---: |
| `grep50`, before fix | 50 | 303.1 MB |
| `grep50-fixed` | 50 | 155.2 MB |
| `grep50-boundary` | 50 | 176.9 MB |
| `grep300`, fixed boundary | 300 | 869.3 MB |

On the 300-step run, RSS later fell to about 610 MB while `footprint` exceeded 1.9 GB because macOS compressed the write-once arena pages. RSS is therefore not a sufficient regression metric. The harness and measurement instructions live in `kfx/repro/README.md`.

The old fix is real and remains necessary. This incident does not show that tool-call or checkpoint scratch reverted to its old ownership. It shows that the next retained boundary is large enough to remain fatal under concurrent long turns.

## Remaining provider-attempt retention

One C-allocator-backed arena is created for an entire prompt and freed only when the turn returns in `src/core/agent/runtime/orchestrator.zig:2740-2742`. Every semantic model attempt passes that allocator to `streamModelCompletion` at `src/core/agent/runtime/orchestrator.zig:3599-3605`, and `src/core/agent/runtime/gateway_step.zig:46-71` passes it directly into the selected provider.

The OpenAI Codex provider uses that allocator for all of the following:

1. `buildRequest` constructs the complete request JSON in an allocating writer at `src/gateway/openai_codex.zig:46-108`.
2. `streamCompletion` calls `alloc.free(payload)` at `src/gateway/openai_codex.zig:131-147`. Arena free is ineffective, so every completed request body remains until turn exit.
3. `streamPrepared` creates a new `std.http.Client` with the same allocator at `src/gateway/openai_codex.zig:186-240`. Client and request deinitialization cannot individually reclaim arena allocations.
4. Replaying assistant provider state parses each stored JSON value with the same allocator at `src/gateway/responses_protocol.zig:47-59`.
5. The streaming reducer parses every SSE event into a JSON DOM with the same allocator at `src/gateway/responses_protocol.zig:248-260`. `parsed.deinit()` cannot reclaim those per-event allocations from the arena.

The same pattern is not Codex-specific. The native Vercel gateway provider builds its request body, authorization header, and HTTP client from the same allocator at `src/builtins/gateway.zig:507-530` and `src/gateway/client.zig:1305-1330`, and the Grok provider does the same at `src/gateway/xai_grok.zig:224`. Every native provider shares the retention class, which is why the fix belongs at the orchestration boundary.

Production reaches this boundary from exactly two call sites, the semantic attempt at `src/core/agent/runtime/orchestrator.zig:3597` and the credential replay at `src/core/agent/runtime/orchestrator.zig:3959`. `image_provider.inspect` is a separate vision-only path that already runs under a per-call arena since the tool fix, so it is outside this change.

The commit message for `5a314dba` explicitly records this boundary: the 50-step grep peak fell from 303 MB to 177 MB, while "the remaining growth is per-attempt provider request assembly, which is a separate change."

### The ownership contract already exists

The result type is already shaped for a non-arena allocator, which makes the repair smaller than a new contract:

- `src/core/agent/stream_provider.zig:262-300` defines `Result.ownership` with `owned` and `borrowed` variants and `Result.deinit(alloc)`. All three native providers return `owned` results.
- Every retry path in the orchestrator already calls `stream_result.deinit(arena)` at `src/core/agent/runtime/orchestrator.zig:4103`, `4138`, and `4269`. These calls are no-ops today only because the allocator is the turn arena.
- On success, `retainCompletedResultInTurnArena` at `src/core/agent/runtime/orchestrator.zig:2123` flips the flag to `borrowed` so the turn arena keeps the result.

Once the attempt allocator differs from the turn arena, the existing retry-path `deinit` calls become real reclamation without modification. The only structural change is replacing the flag flip with a deep copy into the turn arena.

The following escape surfaces were audited and need no copy: the usage ledger duplicates `generation_id` with its own allocator at `src/core/session/session_usage.zig:4582`, and `startDeferredReconciliation` takes only enum values and the job-owned credential. Streaming callbacks copy chunks into `StreamChunkContext`, whose allocator defaults to the C allocator at `src/core/agent/runtime/assistant_stream.zig:64`. `latest_recovery_diagnostic` is a fixed 256-byte array and `preserved_tool_evidence` is an enum. The copy-out surface is the `Result` value itself.

The source audit proves this retention class exists. The incident shape makes it the leading explanation because two 30-step child turns and one 12-step parent turn were live in one process, with large real Codex request and response shapes. A postmortem cannot prove that every one of the 48,617 MiB came from this stack. The fake SSE reproduction did not reach comparable growth, so a real-response-specific amplification or another missed transient path may also contribute. Exact attribution requires a live `footprint`, `vmmap`, or `malloc_history` capture before the kernel kills the task.

Confidence levels:

| Finding | Confidence |
| --- | --- |
| macOS killed PID 70716 because paging space was exhausted | certain |
| PID 70716 owned 48,617 MiB of logical compressed internal pages | certain |
| the running binary contained the tool/checkpoint fix | certain |
| the old tool and checkpoint ownership paths are fixed | high |
| provider attempts still retain scratch in the turn arena | certain from source |
| concurrent in-process subagents amplified process memory | high |
| provider-attempt retention alone accounts for all 48,617 MiB | not proven postmortem |

## Context and quota amplification

There are two different meanings of context growth.

### Per-request context window

Allocator retention does not add messages or tokens to the next request. Changing provider scratch ownership will not reduce the context length seen by the model. The semantic context remains the stable prefix, durable history, current-turn suffix, and active prompt selected by the orchestrator.

### Cumulative input usage

Cumulative usage is amplified by a long tool turn. Every model step resends the prior current-turn messages, including earlier assistant tool calls and tool results. If the initial request contains \(C_0\) tokens and step \(j\) adds \(r_j\) tokens, input usage across \(n\) attempts is approximately:

\[
U = nC_0 + \sum_{j=1}^{n-1}(n-j)r_j
\]

With similarly sized results, the second term is quadratic in the number of steps. Three subagents add three independent growth curves. A retry adds another copy of the full current context without adding useful progress.

The parent usage ledger demonstrates this effect. The numbers below are cumulative across the process's parent and child provider admissions:

| Time | Usage `next_sequence` | Cumulative input tokens | Input tokens added by the request |
| --- | ---: | ---: | ---: |
| 13:03:15 | 22 | 2,640,835 | 224,761 |
| 13:03:27 | 23 | 2,863,844 | 223,009 |
| 13:04:31 | 28 | 4,138,682 | 272,961 |
| 13:05:39 | 32 | 5,309,850 | 302,857 |
| 13:06:03 | 34 | 5,949,675 | 321,664 |

After the 13:03:15 completion and through 13:06:03, twelve further requests added 3,308,840 input tokens. Including the 13:03:15 request, thirteen requests added 3,533,601 input tokens. More child requests completed after the last parent usage checkpoint. This workload can explain why the Codex five-hour quota was exhausted.

Provider-attempt memory retention follows a related curve because each assembled request body and each parsed response event remains allocated. The same repeated context that consumes input quota is also serialized into a fresh retained payload. The two symptoms are correlated, but one does not cause the other:

- An attempt-scoped allocator fixes memory reclamation while sending the same tokens.
- Context compaction, result projection, prompt caching, fewer agent steps, or lower subagent concurrency reduce context or quota usage but do not repair allocator ownership.
- A rate-limit response can couple them operationally. Codex maps HTTP 429 to `rate_limited` in `src/gateway/openai_codex.zig:344-355`; the orchestrator may retry with bounded backoff at `src/core/agent/runtime/orchestrator.zig:4149-4278`. Every retry resends the large context and creates another attempt's scratch.

No durable checkpoint in this incident has cause `rate_limited`, and the system log contains no quota diagnostic. The final child streams transferred substantial response bodies through the kill. Quota exhaustion is therefore best treated as evidence of the request volume, not as the established start of a retry storm.

## Recommended fix

Introduce an attempt-scoped allocator at the orchestration-to-provider boundary, not provider-specific point fixes.

For every provider attempt:

1. Create a C-allocator-backed attempt arena at the top of each attempt-loop iteration, in the same scope as `defer stream_ctx.deinit()` at `src/core/agent/runtime/orchestrator.zig:3295`. Iteration scope covers both the semantic attempt and the credential replay at `orchestrator.zig:3959`, which overwrites `stream_result` without releasing the first `unauthorized` failure; one arena per iteration frees both together.
2. Pass the attempt allocator through `streamModelCompletion` and into the provider in place of `arena`.
3. Keep request serialization, HTTP client state, provider-state replay parsing, SSE parse trees, and provider-local reducers in that arena.
4. Replace `retainCompletedResultInTurnArena` with a deep copy of the whole `Result` into the turn arena. Both variants must be copied. The post-loop code reads `streamFailure(stream_result).detail` at `orchestrator.zig:4617` when retries are exhausted, so a `failed` result that leaves the loop needs `detail`, `diagnostics.schema`, and `diagnostics.request_shape` duplicated. The current function ignores `failed`.
5. Release the attempt result before the retry backoff wait. Today `wait_for_recovery_deadline` runs at `orchestrator.zig:4253` and `4456` before the matching `stream_result.deinit` at `4269` and `4475`, so a rate-limited attempt would hold its full parsed response through the sleep. Move the release ahead of the wait.
6. Run `normalize_terminal_request_tool_calls` with the attempt allocator, or after the copy-out. At `orchestrator.zig:3980` it writes turn-arena tool-call slices into a result still marked `owned`, so the later `deinit` would release turn-arena memory through the attempt allocator. `ArenaAllocator.free` makes this a silent no-op rather than a crash, but it is exactly the ownership mix the tripwire below must reject.

The copy-out contract must cover completion content, tool calls and arguments, provider state, usage, failure detail, and any status fields read after return. Concretely, `src/core/shared/types.zig` has `dupeToolCallSlice` but no `dupeModelCompletion`; add one that duplicates `content`, `generation_id`, `billing.model`, `provider_failure_detail`, `provider_state_json`, and `tool_calls`, and a matching failure duplicate. Put a `comptime` field-count assertion on `ModelCompletion` and `Failure` inside those functions so a future field cannot silently escape the attempt arena. The turn arena is the correct destination: `completion.content`, `provider_state_json`, and `tool_calls` are borrowed into `within_turn_suffix` at `orchestrator.zig:4939`, `5171`, and `5067` and live until the turn ends.

Streaming callbacks may borrow attempt-owned chunks only for the duration of the callback; anything appended to `StreamContext` must use its longer-lived result allocator, which is already the case.

Do not add isolated C-allocator calls inside `openai_codex.zig`. That would leave the same ownership bug in other providers and create many local cleanup contracts. The existing tool fix established the correct pattern: one scratch owner, one result owner, and one copy-out boundary.

### Expected bound after the fix

`parsed.deinit()` inside the attempt arena stays a no-op, so one attempt still holds the JSON DOM of every SSE event it received until the attempt ends. The per-attempt ceiling is proportional to the full response size, not constant. That is sufficient for this incident, where about 100 attempts each needed to release, but the reproduction must use real response shapes or it will understate the per-attempt peak.

### Subagent inspect-wait scratch

`executeModelInspection` in `src/core/subagent/tool_host.zig` gives each 100 ms poll its own C-allocator-backed arena and passes it to `manager.execute`; `encodeResult` already serializes the returned inspection into the caller's allocator, so nothing crosses the poll boundary by reference. The other `while (true)` loops in `tool_host.zig` (recovery condition wait, identity process wait) allocate nothing per iteration and need no change.

The pattern is now the same at every boundary the incident touched: a long-lived arena handed to something that allocates repeatedly gets replaced by a scoped arena plus one copy-out. Any future loop that calls into `manager`, the session stores, or a provider with a caller's arena should be read with that in mind.

### Verification

1. Add a focused unit test that returns a provider completion allocated entirely from an attempt arena, copies it out, destroys the attempt arena, and reads every surviving field. Cover the `failed` variant the same way.
2. Add allocation-failure coverage for partial copy-out cleanup, following the existing pattern in `src/gateway/vercel_protocol.zig:882`.
3. Extend the fake Codex reproduction with real-response-shaped encrypted provider state and SSE event counts. Measure `footprint`, not only RSS.
4. Run 50-step and 300-step repository-grep turns and compare the memory plateau against `grep50-boundary` and `grep300`.
5. Run three concurrent one-off subagents with at least 30 provider steps each. The parent process must remain bounded after each child completes.
6. Exercise a bounded 429 sequence. Confirm each failed attempt arena is destroyed before backoff and cumulative input usage still reports every actual request.
7. Build and run the changed `./zig-out/bin/fx` on the happy path before reporting the fix.

### Results, 2026-08-29

Measured with `kfx/repro` against the fake Codex endpoint. Baseline is the incident binary (`~/.local/bin/kfx`, revision `c238ac38`, tool and checkpoint fix only); fixed is the `fix-turn-arena-tool-retention` build with the attempt arena. Requests include retried ones.

| Run | Requests | Baseline peak RSS | Fixed peak RSS | Fixed peak footprint |
| --- | ---: | ---: | ---: | ---: |
| `grep50` | 51 | 176.9 MB | 47.8 MB | not sampled |
| `grep300`, paced | 301 | 869.3 MB | 96.0 MB | 76 MB |
| `grep50-429`, one 429 before every 10th step | 56 (5 retried) | 174.6 MB | 63.7 MB | 55 MB |
| `subagents3`, parent 35 steps + 3 one-off children x 30 | 129 | 340.1 MB | 165.6 MB | 156 MB |
| `subagents100`, parent 105 steps + 3 one-off children x 100, paced | 409 | 1060.5 MB | 256.0 MB | 323 MB |

The 429 run recovered every rate-limited step through the bounded retry path (`cause=rate_limited`, provider attempts 2/10 through 6/10) and the trace shows 56 `provider_admitted` events for 56 server requests, so cumulative usage still counts every actual request.

The fixed `subagents100` footprint keeps rising because malloc retains freed large chunks: at 408 requests `vmmap` shows 12.8 MB live `MALLOC_LARGE` against 181 MB `MALLOC_LARGE (empty)`. Live memory peaked at 119 MB while all four turns were in flight (request 264) and fell as children finished. The baseline grows about 4 MB per request with no plateau. A paced single-turn `grep200` run sampled with `malloc_history` at step 180 held 27.6 MB of live C-allocator memory, which is the turn's own context growth.

### Real Codex, fixed build, 2026-08-29

Installed `kfx` at revision `5ec0d24b` (the attempt-arena commit cherry-picked onto `kfx`), interactive TUI, real ChatGPT Codex endpoint, `memwatch.sh` sampling the process every 2 s (`~/kfx-mem3.csv`). Session `1788010110141`, second turn: `read_file` on 30 files over 400 lines each, one file per step as instructed; the model batched some reads, giving 16 requests, 15 tool steps, and 38 tool results totalling 355 KB with every result at the 16 KB cap, the same result shape as the incident turn.

| Phase | RSS | Footprint |
| --- | ---: | ---: |
| idle before the turn | 23.5 MB | 17 MB |
| during the 15 steps | 25 to 40.5 MB | 18 to 26 MB |
| idle after the turn | 38.5 MB | 21 MB |

After the turn `vmmap -summary` showed no live `MALLOC_LARGE` region, 2.3 MB of empty large chunks, and 14 MB of small allocations. The whole turn added 9 MB of footprint and released it on return. An earlier 17-step turn in session `1788008785504` (18 requests, 40 tool results) was not sampled while running because the sampler was attached to a second `kfx` process, but its post-turn state was the same: no live large allocations, 91 MB of dirty freed malloc pages.

### Real Codex, three one-off subagents: the second retained boundary

The same build with the incident topology (`~/kfx-mem4.csv`, session `1788010855169`, parent 26 requests and 25 steps, three one-off children reading files) reached a peak footprint of 57,344 MB with RSS at most 4.2 GB, the incident's magnitude. Footprint fell to 8 GB when the children finished and to 1.4 GB after the parent returned, all of it `MALLOC_LARGE (empty)` with 11 MB live. The attempt arena had released its scratch; a different path retained tens of GiB while the children ran.

The parent's tool results name it. The model waited for the children with `subagent inspect` plus `wait: {until: settled, timeout_ms: 60000}` (four `wait_timed_out` results). `executeModelInspection` in `src/core/subagent/tool_host.zig` polls every 100 ms: each poll runs `manager.execute(alloc, inspect)`, which loads every locked child's `control.json` through `loadLockedGraph` and clones the target child's messages and events, all from the tool call's arena, and `result.deinit(alloc)` reclaims nothing. One wait is up to 600 polls, and the child's event list grows as it works, so each snapshot is larger than the last. The incident parent's last durable state, waiting for its one-off children, is this loop.

Reproduction with `INSPECT_WAIT=2` (parent issues two inspect waits per child before its own steps), 3 children x 30 steps, paced responses:

| Build | Requests | Peak footprint | Live `MALLOC_LARGE` at peak |
| --- | ---: | ---: | ---: |
| attempt arena only | 100, killed at 202 s | 14,336 MB | 1.4 GB at 93 s and climbing |
| attempt arena + per-poll arena | 139, completed | 244 MB | released after the children finished |

The same workload without inspect waits (`tui-subagents3-paced`) peaked at 115 MB on the attempt-arena build, which is why earlier fake runs never showed this path.

Retest on the real endpoint with both fixes installed (`kfx` at `124c7a1e`, `~/kfx-mem5.csv`, session `1788012867288`): parent 8 requests, three one-off children, one `wait_timed_out` and three `completed` inspections. Peak footprint 193 MB at 155 s with 18 threads alive, 76 MB after the children finished, all of it empty malloc chunks with 14 MB live. The earlier run of the same prompt on the attempt-arena build had passed 12 GB by the same elapsed time.

The fix gives each poll a C-allocator-backed arena; `encodeResult` already serializes the returned inspection into the caller's allocator, so the copy-out boundary existed. Nine lines in `tool_host.zig`. Whether the incident's 48 GiB split between the attempt path and the wait loop cannot be recovered postmortem; both are closed.

Step 5 of the recommended fix, releasing the failed attempt before the backoff wait, was not implemented: the post-wait cancel branch still reads `response_completion.tool_calls`, so the reorder needs that branch restructured. The cost is one attempt's scratch held through one sleep, not cumulative.

Unit tests: `types.zig` `dupeModelCompletion` with an 11-field `ModelCompletion` and 9-field `ProviderBilling` tripwire; `orchestrator.zig` `copyStreamResultToTurnArena` copies both variants out of an attempt arena that is then destroyed. `zig build test` passes; `fx ask` plain and tool-calling turns run against the real Codex endpoint.

## Single-turn simulation prompt

Exercises the provider-attempt boundary alone: one turn, 30 `read_file` steps on files over 400 lines, every result at the 16 KB cap. This is the prompt behind the 15-step real-session curve above; the model batches some reads, so expect 15 to 20 steps. Sample with `memwatch.sh` on the `kfx` pid.

```text
逐一用 read_file 讀下列 30 個檔案，每個檔案一步，不要用 terminal 或 grep 合併；每讀完一個就記下它的公開函式數與最長的函式名稱，30 個都讀完再一次回報成表格，中間不要停下來問我：
src/core/session/session_store.zig
src/core/agent/runtime/orchestrator.zig
src/gateway/client.zig
src/core/session/session_log.zig
src/core/session/session.zig
src/core/session/session_usage.zig
src/core/session/session_codec.zig
src/core/session/session_commands.zig
src/core/session/session_event.zig
src/core/agent/runtime/tool_presentation.zig
src/core/session/session_summary_codec.zig
src/core/session/session_json.zig
src/core/agent/runtime/assistant_stream.zig
src/core/session/command_replay_store.zig
src/core/agent/runtime/vision_contracts.zig
src/core/session/session_child_store.zig
src/core/session/profile_usage_store.zig
src/gateway/vercel_protocol.zig
src/core/session/prompt_history_store.zig
src/core/agent/runtime/tool_admission.zig
src/gateway/xai_grok.zig
src/core/session/session_migration.zig
src/core/agent/runtime/execution_memory.zig
src/core/session/result_store.zig
src/core/session/usage_report.zig
src/gateway/openai_codex.zig
src/core/session/session_projection.zig
src/gateway/xai_grok_models.zig
src/gateway/responses_protocol.zig
src/core/session/session_discovery.zig
```

A prompt that lists patterns to grep does not work as a step driver: the model folds all of them into one or two `terminal` commands.

## Full-length simulation prompt

The retest above covered the phase where the old build exploded but ran shorter than the incident. This prompt reproduces every phase of the 57 GiB run: three one-off children reading 30 files each, the parent rotating `inspect wait` calls with 60 s timeouts until all three complete, then 15 `read_file` verification steps that push the parent's context toward the incident's 900 K tokens. Sample with `memwatch.sh` on the `kfx` pid (`ps -o pid,lstart,command -x | grep '[k]fx$'`). Expect 6 to 8 minutes and about 110 requests.

```text
用 subagent 工具依序建立三個 mode=one_off 的子代理（三個都建好再開始等，不要建一個等一個）。每個子代理規則相同：只能用 read_file，一個檔案一步，不可用 terminal、grep_files、glob_files，不可一步讀多個檔；每讀完一個檔記下該檔的 pub fn 數量與最長的函式名稱；指定的 30 個檔全部讀完後，回報一份 30 列的表格（檔名、pub fn 數、最長函式名）。

child-session 讀：
src/core/session/session_store.zig src/core/session/session_log.zig src/core/session/session.zig src/core/session/session_usage.zig src/core/session/session_codec.zig src/core/session/session_commands.zig src/core/session/session_event.zig src/core/session/session_summary_codec.zig src/core/session/session_json.zig src/core/session/command_replay_store.zig src/core/session/session_child_store.zig src/core/session/profile_usage_store.zig src/core/session/prompt_history_store.zig src/core/session/session_migration.zig src/core/session/result_store.zig src/core/session/usage_report.zig src/core/session/session_projection.zig src/core/session/session_discovery.zig src/core/session/session_latest_pointer.zig src/core/session/session_authority.zig src/core/session/session_usage_sidecar.zig src/core/session/session_replay.zig src/core/session/profile_usage_runtime.zig src/core/session/usage_recovery.zig src/core/session/session_resume_view.zig src/core/session/web_fetch_artifacts.zig src/core/session/session_display_metadata.zig src/core/session/usage_menu.zig src/core/session/session_relationship_index_codec.zig src/core/session/session_store_types.zig

child-runtime 讀：
src/core/agent/runtime/orchestrator.zig src/core/agent/runtime/tool_presentation.zig src/core/agent/runtime/assistant_stream.zig src/core/agent/runtime/vision_contracts.zig src/core/agent/runtime/tool_admission.zig src/core/agent/runtime/execution_memory.zig src/core/agent/runtime/parallel_execution.zig src/core/agent/runtime/vision_executor.zig src/core/agent/runtime/tool_batch.zig src/core/agent/runtime/gateway_step.zig src/core/agent/runtime/model_response_recovery.zig src/core/agent/runtime/telemetry.zig src/core/agent/runtime/lifecycle.zig src/core/agent/runtime/interruption.zig src/core/agent/runtime/prompt_context.zig src/core/agent/runtime/finalization.zig src/core/agent/runtime/deps.zig src/core/agent/runtime/stop_policy.zig src/core/agent/runtime/image_provider.zig src/core/agent/runtime/tool_contracts.zig src/core/agent/runtime/config.zig src/core/agent/stream_provider.zig src/core/shared/types.zig src/core/shared/debug_trace.zig src/core/shared/io.zig src/core/shared/text_utils.zig src/core/tooling/tool_runtime.zig src/core/tooling/tool_dispatch.zig src/core/tooling/model_tool_schema.zig src/builtins/tools.zig

child-gateway 讀：
src/core/subagent/manager.zig src/core/subagent/execution.zig src/gateway/client.zig src/core/subagent/tool_host.zig src/core/subagent/communication.zig src/core/subagent/control_store.zig src/core/subagent/ui_projection.zig src/core/subagent/communication_store.zig src/core/subagent/domain.zig src/core/subagent/parent_delivery_projector.zig src/gateway/vercel_protocol.zig src/core/subagent/relationship_index.zig src/core/subagent/approval_registry.zig src/gateway/xai_grok.zig src/core/subagent/create_store.zig src/core/subagent/communication_manager.zig src/gateway/openai_codex.zig src/core/subagent/resume_admission.zig src/core/gateway/model_catalog.zig src/core/subagent/approval_persistence.zig src/gateway/xai_grok_models.zig src/gateway/responses_protocol.zig src/core/subagent/agent_adapter.zig src/core/subagent/authority.zig src/core/gateway/gateway_provider.zig src/gateway/responses_permission_reviewer.zig src/gateway/generation_usage.zig src/gateway/host_stream_provider.zig src/gateway/openai_codex_models.zig src/core/subagent/tool_result.zig

三個都建立後，你用 subagent inspect 等他們：sections 只帶 status，wait 用 until=settled、timeout_ms=60000，先等 child-session，timeout 就換 child-runtime，再換 child-gateway，輪著等，直到三個都回報 completed 為止；等待期間不要做別的事。

三個都完成後，從三份表格各挑「最長函式名稱」最長的 5 個檔案，共 15 個，逐一用 read_file 讀回來確認那個函式真的存在，一檔一步，不可合併。最後把三份表格和你的 15 筆驗證結果合成一份給我。
```

Run of this prompt on `124c7a1e` (`~/kfx-mem6.csv`, session `1788013572046`): three children created at t=5, parent rotating `inspect wait` (two timeouts, two completions) until t=165, 22 threads at peak. Footprint 33 MB when the children started, 60 to 69 MB while all four turns were alive, 28 MB after the parent returned; no live `MALLOC_LARGE`. The 57 GiB run was at 3.6 GB one minute into the same phase.

The flow did not finish: `child-gateway` finished while the parent was waiting on `child-session`, and by the time the parent inspected it (about 30 s later) the one-off retirement sweep had deleted its committed session and relationship entry, so every later inspect returned `child_unavailable`. The prompt's `sections: status` also meant the completed inspections carried no report text. Neither touches the memory patches: `isAttached` runs on the runtime's own allocator and retirement lives in `execution.zig`. Ask for `sections: [status, messages]` and inspect each child at least once right after its wait settles if the reports matter.

Reference curve from the 57 GiB run, measured from the moment the child threads appeared: 3.6 GB at +60 s, 6.4 GB at +100 s, 12 GB at +140 s, above 45 GB before the children finished, 8 GB after they finished, 1.4 GB after the parent returned. The build with both fixes should stay in the hundreds of MB through every phase and fall when the children finish.

## Branch and pull request recommendation

Continue on `fix-turn-arena-tool-retention` and include this repair in the same upstream pull request, [vercel-labs/fx#484](https://github.com/vercel-labs/fx/pull/484).

As of this investigation, PR #484 is still a blocked draft and has not run Full CI. Its two commits are content-equivalent to `5a314dba` and `c238ac38` on `kfx`. There is no review or green exact-commit CI result to preserve. A separate parallel branch would either depend on an unmerged allocator contract or duplicate the incident harness and ownership review.

Keep the work reviewable as separate commits in one PR:

1. Tool-call and recovery-checkpoint scratch ownership, `ad5995ab`.
2. MCP lifetime follow-up, `13f7e60d`.
3. Provider-attempt scratch ownership and copy-out, `9c00376b`.
4. Subagent inspect-wait poll scratch, `0821880f`.

On `kfx` the same four are `5a314dba`, `c238ac38`, `7659f29a`, `89c40b40`, each followed by its inventory commit.

Retitle the PR from `Fix tool-call and checkpoint scratch memory leak` to `Fix turn-arena memory retention`, or another title that covers all three retained boundaries. Keep the PR classification `type: bug`.

Use a separate PR only if the existing change has already entered final review and maintainers explicitly want the narrower patch merged first. That condition does not hold now. Merging PR #484 while knowingly leaving the incident's remaining fatal path would create false confidence that long turns are safe.

The upstream implementation must be made on `fix-turn-arena-tool-retention`, not on `kfx`, because `kfx` contains unrelated fork patches. After upstream review, rebase or cherry-pick the resulting commits back into `kfx` as the fork already does for the first two fixes.

## Operational precautions

Until the provider boundary is fixed:

- Free substantial disk space before resuming this session so macOS has paging headroom.
- Avoid several long one-off subagents in one parent process.
- Bound agent steps for incident-shaped research tasks.
- Capture `footprint`, `vmmap -summary`, and `malloc_history -allBySize` while reproducing. Postmortem session files cannot recover allocator stack attribution after SIGKILL.

These precautions reduce the chance of another kill. They do not replace the allocator fix.
