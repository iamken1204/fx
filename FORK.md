# Fork Notes

This is the `kfx` personal fork of [vercel-labs/fx](https://github.com/vercel-labs/fx) (`kfx` reads as k·f(x): upstream scaled by a personal constant). The fork branch is `kfx`, and `make install` installs the binary as `kfx` so it never shadows an upstream `fx` on PATH; the build output stays `zig-out/bin/fx` because `build.zig` is upstream code. This file exists only in the fork, so it never conflicts with upstream. Read it before rebasing onto upstream `main` or extending fork behavior, and keep the patch inventory below current.

## Features

| Feature | Enable | What it does |
| --- | --- | --- |
| Profile system prompt | Write `~/.fx/SYSTEM.md` | Replaces the compiled system prompt across TUI, `fx ask`, ACP, and subagents. `fx ask --system` still overrides it; `fx doctor` reports invalid files |
| Exclude builtin tools | `FX_EXCLUDE_TOOLS=name1,name2` | Hides the listed builtin tools from model advertisement; the registry stays full |
| Evict old tool results from the request | `FX_KEEP_RECENT_RESULTS=N`, `FX_EVICT_THRESHOLD_KB=T` (default 256) | When the evictable tool-result bytes reach `T` KiB, one sweep replaces every result older than the newest `N` steps with a one-line stub carrying a `read_tool_result` handle; between sweeps the projected prefix is byte-identical so the prompt cache keeps hitting. Session log, checkpoints, and resume keep the full text |
| Skill catalog by source | `FX_SKILL_SOURCES=claude,fx` | Advertises only skills from the listed roots (`fx`, `workspace`, `claude`, `codex`, `agents`, `opencode`, `claw`); skills with `disable-model-invocation: true` are always hidden from the model. The `/skill` menu still lists everything |
| Codex account in provider picker | Select the Codex provider | Shows the signed-in ChatGPT email beside the active Codex row in `/provider`; falls back to a masked account ID when the access token has no usable email claim |

Recommended setup:

```bash
export FX_EXCLUDE_TOOLS=vision,web_search
export FX_KEEP_RECENT_RESULTS=4
export FX_SKILL_SOURCES=claude
./zig-out/bin/fx --context-limit skill_description_bytes=512
```

One profile-prompt rule in `~/.fx/SYSTEM.md` keeps the model from delegating investigation. Measured on 2026-08-30 with the same read-only evaluation prompt on `gpt-5.6-sol` medium: the stock prompt spawned two children, timed out twice at the then 60 s inspect-wait cap, cancelled one unread, and spent 3.38M input tokens over 6m24s; with the rule the same prompt ran 0.6 to 1.1M tokens in 2 to 3.5 minutes.

```text
Delegation
- Investigation, review, and evaluation are your own work: read the files yourself. Create a child session only for work that is independent of the answer you are writing, and start its prompt with "You are a subagent. Don't run memo."
```

Upstream replaced the polling `inspect.wait` action on 2026-09-01: `subagent` now exposes `run` (one temporary child, the call blocks until its terminal result) and `message` (a persistent child), so the parent can no longer time out or cancel a child unread. The second rule this file used to carry, waiting at the full timeout and reading before cancelling, has nothing left to steer; drop it from `~/.fx/SYSTEM.md`.

Add `"max_tool_result_bytes": 16384` to `~/.fx/settings.json` (upstream key, minimum 1024) to bring the per-result cap in line with Codex CLI and Claude Code; 64 KB is the loosest default among the harnesses. Child sessions record their own usage now (`usage-v2.json` and `usage_checkpointed` events), so `fx usage` on a child session reports real numbers. [context-budget.md](kfx/specs/context-budget.md) has the measurements behind these settings.

The exclusion list above drops tools that compensate for weaker models behind the Vercel AI Gateway (vision fallback, provider-side web search). The gateway currently tries Exa before Parallel for `web_search`; no separate Exa API key is needed, but [Exa requests are billed through AI Gateway](https://vercel.com/docs/ai-gateway/models-and-providers/web-search#using-exa-search). On frontier models these tool schemas pollute context without adding capability. Upstream removed the typed filesystem tools (`list_files`, `file_info`, `delete_file`, `rename_file`, `copy_file`, `create_folder`) and `semantic_search` on 2026-08-27, so they no longer need excluding; unknown names in the list are ignored.

Tool-call folding is upstream behavior now: enable `Collapse tool calls` in `/settings` or set `"collapse_tool_calls": true` in `~/.fx/settings.json`. The fork's `FX_COMPACT_TOOL_CALLS` patch was dropped on 2026-08-29 in favor of it; upstream hides every child row behind the group header, including failed and running ones, and the ctrl+o full transcript keeps the detail.

## Caveats

If you want to use `kfx`, run `make install`. The installed binary at `~/.local/bin/kfx` can auto-upgrade according to the channel in `~/.fx/settings.json`, so it may no longer match the source tree. For development, run `./zig-out/bin/fx` directly. To disable auto-upgrades, set `FX_AUTO_UPGRADE=0` for one invocation or add `"auto_upgrade": false` to `~/.fx/settings.json`.

## TODO

Nothing in this section exists in the tree yet; do not document any of it as existing behavior.

Specs live in `kfx/specs/`, one file per intent, each opening with a status line. This table is the index; keep it current. When a spec lands, add its patches to the inventory below and delete the spec file (git history keeps it). `idea` means a sketch worth keeping; `spec` means ready to implement.

| Spec | Status | Intent |
| --- | --- | --- |
| [de-vercel.md](kfx/specs/de-vercel.md) | idea | Keep remaining Vercel surfaces dormant through configuration; patch cosmetic exposure only if it bothers |
| [mid-turn-steering.md](kfx/specs/mid-turn-steering.md) | idea | Inject queued user messages into the running turn at step boundaries instead of the next turn |
| [local-web-control-plane.md](kfx/specs/local-web-control-plane.md) | spec | Add a single-user loopback web UI that lists every durable local session and continues dormant or actively owned sessions through one typed control plane |
| [context-retention.md](kfx/specs/context-retention.md) | spec | Phase 1: raise the 8-turn compaction ceiling behind `FX_MAX_HISTORY_TURNS`; move the ephemeral overlay behind history so kept history joins the cacheable prompt prefix |
| [recoverable-session-history.md](kfx/specs/recoverable-session-history.md) | spec | Phase 2: add stable locators, omission landmarks, deterministic search, and bounded exact reads for canonical turns outside the prompt horizon |
| [turn-arena-memory-growth.md](kfx/specs/turn-arena-memory-growth.md) | landed, kept | Incident record for the 2026-08-29 48 GiB kill: four retained turn-arena boundaries, their fixes, the `kfx/repro` reproductions, and the real-session curves; kept because the patch inventory alone does not carry the evidence |
| [multi-brain-arch.md](kfx/specs/multi-brain-arch.md) | spec | Event-router persistent child that arbitrates background events into defer or wake without blocking the main session |
| [context-budget.md](kfx/specs/context-budget.md) | landed, kept | Where the 2026-08-29 session's 30M input tokens went, the four levers ranked by savings, the harness comparison, and what was deliberately not patched (the `shell` tool schema, then named `terminal`, and `AGENTS.md`); kept for the measurements |
| [threshold-eviction.md](kfx/specs/threshold-eviction.md) | landed, kept | Replaces the per-batch eviction advance with a byte threshold (`FX_EVICT_THRESHOLD_KB`, default 256) so the projected prefix stays cache-stable between sweeps; kept for the 2026-09-01 cache-reset measurements |

Context-retention rollout: ship Phase 1 Patch A and Patch C first; then add Phase 2 locator/read, search, and retrieval guidance patches. Reconsider the optional Phase 1 history-budget increase only after Phase 2 measurements. Phase 2 complements the directly visible recent-history path rather than replacing it.

Overlap note: context-retention Patch C and the multi-brain prompt cache boundary both reorder prompt assembly so overlays sit after durable history. Whichever lands first defines the merge slot; the other must reuse it, not add a second one. Recoverable-history tool observations belong in the existing non-cacheable within-turn suffix and must not create another overlay. Upstream response-language control now runs through `build_provider_prompt_with_response_language_control`, which adds a `no_cache` system message to the ephemeral overlay on eligible root turns and a trailing user correction message after a rejected candidate. Both are transient and must stay outside the cacheable prefix when the overlay moves.

The result-eviction patch projects the within-turn suffix at both `build_provider_prompt_with_response_language_control` calls in the step loop; context-retention Patch C and multi-brain must keep that projection on the suffix argument when they move the overlay. Upstream [PR #471](https://github.com/vercel-labs/fx/pull/471) landed on 2026-09-02: it compacts model context at 80% of usable input and continues from a checkpoint, slicing the suffix by index, which the projection preserves because stubs replace content in place. The compaction summary is built from the canonical suffix, never the projection, so evicted results still reach the summarizer in full. Eviction stays ahead of it as the cheap first pass. Re-check [context-retention.md](kfx/specs/context-retention.md) against the landed compaction before implementing it.

## Maintenance strategy

The fork is a thin patch stack rebased onto upstream `main`.

* One intent per commit. Do not mix fork patches with unrelated work; each patch must be individually keepable or droppable during a rebase.
* Every fork commit carries a body explaining its intent and its conflict policy. During a rebase, read the commit body of the conflicting patch first.
* Prefer additive seams (environment variables, config, new files) over deleting or rewriting upstream code, so patches rarely conflict.
* Enable `git rerere` locally (`git config rerere.enabled true`) so a conflict resolved once replays automatically. Agents must not change git config themselves; ask the user to run it.
* Upstream hot zones that fork goals touch: `src/builtins/tools.zig`, `src/core/tooling/`, `src/gateway/`, `src/core/config/config_runtime.zig`. Expect conflicts there and resolve in favor of the patch's stated policy.

## Patch inventory

Ordered oldest first. Update this table whenever a fork patch is added, dropped, or absorbed by upstream. The stack was restacked on 2026-09-02 into five code commits, each carrying the rows named here: "Load the profile system prompt" (profile prompt and its E2E), "Control model-visible capabilities" (FX_EXCLUDE_TOOLS and the skill filter), "Evict stale tool results by byte threshold", "Reclaim transient turn memory" (both arena patches, the MCP companion, and the compaction scratch), and "Checkpoint child session usage". Rebased onto upstream `2c467350` on 2026-09-04 (79 upstream commits: provider prompt separation, authentication recovery, prompt steering, and cancellation fixes); one conflict in the result-eviction row below.

| Patch | Intent | Conflict policy |
| --- | --- | --- |
| Add a profile system prompt at ~/.fx/SYSTEM.md | User-owned system prompt file replaces the compiled prompt across TUI, ask, ACP, and subagents; `fx ask --system` stays ahead of it; invalid files are refused and reported by `fx doctor` | Keep the profile file lookup ahead of the compiled prompt; if upstream reshapes prompt assembly, re-attach the lookup at the new assembly point. Since 2026-09-03 the `main.zig` entry configs take an `auth_mode` (host-managed authentication); `cfg` must stay `var` so the loaded prompt can be applied, and the entry-config test calls `fullEntryConfig(.local)` |
| Cover the profile system prompt in E2E | E2E assertions for the doctor report and for the profile prompt reaching the model request | Follows the patch above; update assertions rather than dropping them |
| Hide tools named in FX_EXCLUDE_TOOLS from model advertisement | Comma-separated env var hides builtin tools from the model at the shared projection choke point (`appendBuiltinTool`); vision routing is decided separately by the orchestrator, so `visionPolicy` checks the same list; registry stays full | Keep the `excludedByEnvironment` checks at the top of each filter chain if upstream rewrites `appendBuiltinTool` or the vision policy wiring |
| Reclaim tool-call and checkpoint scratch instead of retaining it in the turn arena | Gives every ordinary tool call a per-call `c_allocator`-backed arena with copy-out of survivors to the result allocator, and builds recovery-checkpoint execution memory in scratch freed on return; fixes a turn-long memory retention that grew until jetsam killed the process (upstream issue [#483](https://github.com/vercel-labs/fx/issues/483)) | Submitted upstream as [PR #484](https://github.com/vercel-labs/fx/pull/484). If it merges verbatim, rebase drops both patches automatically via patch-id; if it merges modified, drop both patches in favor of upstream. Until then expect conflicts in `src/core/tooling/` and the orchestrator hot zones |
| Keep the MCP input-required error code static past the dispatch copy-out | Assigns the static `"McpInputRequired"` after the dispatch copy-out because `PromptRunResult.error_code` is a borrowed pointer never freed by `deinit`; without this the final `fx ask --json` render reads the freed turn arena and crashes with SIGSEGV on Linux (see CI field notes below) | Inseparable companion of the patch above and part of the same upstream PR; keep or drop the two together |
| Reclaim provider-attempt scratch instead of retaining it in the turn arena | Gives each model attempt a `c_allocator`-backed arena for the request body, HTTP client, provider-state replay parse, and SSE parse trees, and deep-copies the surviving `Result` into the turn arena at `copyStreamResultToTurnArena`; the `dupeModelCompletion` tripwire fails the build when a slice-bearing field is added without extending the copy. Fixes the retention that survived the two patches above and reached 48 GiB in the 2026-08-29 incident | Third commit of [PR #484](https://github.com/vercel-labs/fx/pull/484); same drop rule as the two patches above. Conflicts land in the orchestrator attempt loop; keep the attempt arena scoped to one loop iteration and the copy-out before `break` |
| Scope in-turn context compaction to one c_allocator arena | `compactContextTransaction` in the orchestrator step loop runs on a scratch arena that dies with the compaction block instead of the turn arena, and the handoff is copied out; the promoted result copies, the compactor request body, and its stream parse otherwise stayed alive for the rest of the turn. The canonical window stays on the turn arena because the retained history tail is copied from it. Manual `/compact` already runs on its own arena in `app_agent_runtime.zig` | Keep the scratch arena around the transaction call and the `arena.dupe` on the handoff; if upstream reshapes the compaction block, re-scope at the new transaction call |
| Evict old tool results from the model request behind FX_KEEP_RECENT_RESULTS | `src/core/agent/runtime/result_eviction.zig` holds one `State` per turn (bound to the turn arena, the step budget, and the session's `result_store.StorageTarget`); `state.view` runs right before both provider prompt builds in the orchestrator step loop and turns results older than the newest `N` steps into the existing `<tool_result_handle>` stub, storing them through `StorageTarget.store`, the same path the tools use. The boundary advances only when the evictable result bytes reach `FX_EVICT_THRESHOLD_KB` (default 256), so the projected prefix stays byte-identical between sweeps; batch-per-`N` advance cost 23% fresh tokens on a real 2026-09-01 session ([threshold-eviction.md](kfx/specs/threshold-eviction.md)). Canonical suffix, checkpoints, and resume are untouched. Fake Codex, 12 read steps, `N=2`, `T=48`: two prefix resets in 13 requests, stubs readable back through `read_tool_result` | Additive: one new file, `StorageTarget` made public with `fromSession`/`store` in `result_store.zig`, one turn-local `State`, two call-site argument swaps. PR #471 wrapped both calls in `buildProviderPromptForCompactionWindow`, which takes the suffix and a `compacted_suffix_len` index; `view` takes that index as `request_start` so the messages compaction already cut count toward neither the step window nor the threshold, and the projection keeps message positions so the index still applies. Since 2026-09-04 both call sites go through `build_provider_prompt_with_response_language_control`, which separates provider instructions from conversation messages and adds `origin`, `enforce_response_language`, and `correction_attempted` arguments after the suffix; `state.view` stays on that suffix argument. If Patch C moves assembly again, re-attach `state.view` on the suffix argument at the new slot and keep it ahead of any summary compaction |
| Checkpoint subagent usage on child turn commit | `LoadedWritableSession.appendUsageCheckpoint` in `session_log.zig` is the one writer of `usage_checkpointed` events; the app loop and `fx ask` call it inside their profile-recovery prepare/finish pair, and `TurnContext.commit` in `src/core/subagent/execution.zig` calls it after `history_turn_committed` without the marker (children have no profile ledger to recover). Before this, every child session reported zero requests. Fake Codex: child `usage-v2.json` carries the child's input tokens | The helper is additive; the two upstream call sites shrink to one line each and may conflict on rebase, resolve by keeping the helper call. Keep the child call after the history event so a failed commit never records usage |
| Filter the skill catalog by source and honor disable-model-invocation | `skill_contract.zig` parses `disable-model-invocation` through the same value parser as `name`; `skill_runtime.modelVisibleSkills` is the one projection the model sees through, applied by the prompt catalog, the `skill` tool, and `capability_search`, and it also applies `FX_SKILL_SOURCES` (comma-separated `SkillMenuSourceFilter` names, parsed once per call). Discovery and the `/skill` menu keep the full list. `fx doctor` reports `skill_sources` and fails on an unknown name. Real skill roots on this machine: 76 skills, 38 KB, 9.2K tokens before; `FX_SKILL_SOURCES=claude` gives 48 skills, 25 KB | Keep the three call sites on `modelVisibleSkills`; if upstream adds its own `disable-model-invocation` handling, drop that half and keep the source filter |
| Show the Codex account in the provider picker | Extracts the optional namespaced profile email from the existing Codex access token without changing the saved session schema. `credentials.Credential` owns only that identity data; `provider_picker_runtime.zig` chooses email first, otherwise masks the account ID, and appends `current` in the active provider row's existing annotation column | Keep identity extraction in `chatgpt_oauth.zig`, identity ownership on `credentials.Credential`, and all masking and annotation formatting in `provider_picker_runtime.zig`. The active-provider path must stay provider-agnostic and fixed-buffer formatting must fall back to `current` on overflow. If upstream adds provider account identity, prefer its typed field and UI instead of retaining parallel fields |

Dropped on 2026-09-02 while rebasing onto upstream `4ab76173`: "Scope subagent inspect-wait scratch to one poll" (fourth commit of PR #484) and "Raise the subagent inspect-wait ceiling to ten minutes". Upstream removed `inspect.wait` and its 100 ms poll loop; `observeManagedState` in `src/core/subagent/tool_host.zig` now blocks on `managed.wait` until a terminal phase with no per-pulse loading and no ceiling, so both patches have no code to attach to. The incident record in [turn-arena-memory-growth.md](kfx/specs/turn-arena-memory-growth.md) still describes the fourth boundary as it was.

## Verifying after a rebase

1. `zig build test` passes.
2. `zig build`, then confirm the exclusion end to end: point `FX_GATEWAY_CHAT_URL` at a local server that captures the POST body, run `FX_EXCLUDE_TOOLS=vision,web_search ./zig-out/bin/fx ask "hi"`, and check the captured `tools` array omits the excluded names while the baseline run includes them. `web_search` is advertised to the model as the gateway provider tool `exa_search`, so that is the name to look for; `vision` is only advertised when the model lacks native vision.
3. Confirm `~/.fx/SYSTEM.md` still displaces the compiled prompt (`fx doctor` reports the system_prompt check).
4. `cd kfx/repro && DUMP=1 STEPS=12 sh run.sh evict12 FX_KEEP_RECENT_RESULTS=2 FX_EVICT_THRESHOLD_KB=48`, then check `out/evict12/server.log.req13.json` carries `<tool_result_handle>` stubs in place of the older tool outputs and stays well below the unfiltered run (`DUMP=1 STEPS=12 sh run.sh base12`). Without the explicit threshold the default 256 KiB never trips on 12 capped steps and no stub appears; that is the intended cache-stable behavior, not a regression.
5. `FX_SKILL_SOURCES=claude` against the same capture drops every `<location>` outside `~/.claude/skills`, and no skill with `disable-model-invocation: true` appears with or without the variable.
6. Run the freshly built `./zig-out/bin/fx` in a real TTY with Codex active, open `/provider`, and confirm the active row shows the profile email or masked account ID plus `current`; exit through the UI and require clean stderr.

### Provider picker verification notes

* Find the live screen owner before editing. The setup Connections screen is rendered by `src/ui/footer/picker_presentation.zig`, but the slash-command provider rows and annotations are assembled by `src/core/app/provider_picker_runtime.zig`.
* Auth source files are not standalone Zig test roots because their imports depend on the build graph. Run their tests through `zig build test`; direct `zig test src/...` failures do not prove the changed test failed.
* Exercise this path with the freshly built `./zig-out/bin/fx` attached to a real TTY. An isolated `HOME` can carry a permission-restricted copy of `chatgpt-auth.json`; drive `/provider` through tmux, inspect the pane and stderr, exit through the UI, then delete the credential copy.

## CI field notes

Hard-won lessons from debugging Full CI failures locally. Recorded after diagnosing a Linux-only SIGSEGV in `mcp-stdio.test.ts` (a use-after-free introduced by a per-call arena change, 2026-08).

### Reading e2e failures

* `result.code === null` from `runFx` means the process died from a signal (Node reports `code=null, signal=set`), not a nonzero exit. If the test also finished far below its timeout, it is a crash, not a hang.
* A failure that reproduces on both Linux architectures and survives the shard's bounded retry is deterministic. Treat single-platform single-run failures as flakes only after a rerun.

### Allocator-lifetime bugs hide on macOS

* A use-after-free of `ArenaAllocator` memory backed by `c_allocator` typically passes silently on macOS (freed pages stay mapped and intact) and crashes with SIGSEGV on Linux (glibc returns large chunks via `munmap`). Green macOS runs prove nothing about pointer lifetimes; verify allocator-ownership changes on Linux before pushing.
* The ownership trap that caused the crash: `PromptRunResult.error_code` is a borrowed pointer that `deinit` never frees, so every value assigned to it must be static memory. A dispatch-boundary copy-out that dupes `status_detail` onto the turn arena silently broke that contract. When adding copy-out or changing result ownership, audit every consumer that retains a pointer past the turn arena (search for sinks that assign without `dupe`).

### Reproducing Linux CI locally

Docker on Apple Silicon runs `--platform linux/arm64` natively (fast) and `linux/amd64` via emulation (build takes several minutes but works). Recipe that matches CI closely enough:

```bash
docker run -d --init --name fx-repro --platform linux/arm64 \
  -v "$PWD":/src:ro ubuntu:24.04 sleep 7200
docker exec fx-repro bash -c '
  apt-get update -qq && apt-get install -y -qq curl xz-utils git tmux unzip python3
  curl -fsSL https://ziglang.org/download/0.16.0/zig-aarch64-linux-0.16.0.tar.xz | tar -xJ -C /opt
  ln -s /opt/zig-*/zig /usr/local/bin/zig
  curl -fsSL https://bun.sh/install | BUN_INSTALL=/opt/bun bash && ln -s /opt/bun/bin/bun /usr/local/bin/bun
  cp -r /src /work && cd /work && rm -rf zig-out .zig-cache && zig build -Doptimize=ReleaseSafe
  cd tests/e2e && bun install && bun test <failing-file>.test.ts'
```

Container pitfalls that produce false failures:

* Run the container with `--init`. Without a reaper, exited MCP fixture processes stay as zombies and `expectFixtureProcessesExited` reports them as still alive.
* Install `python3`; permission tests shell out to it for `os.getsid`.
* Match the Zig version pinned in `.github/workflows/full-ci.yml`, not whatever Homebrew has.

### Getting a backtrace out of a crash

* Non-Debug binaries are stripped (`build.zig` sets `.strip = optimize != .Debug`), so gdb on the ReleaseSafe binary yields nothing. Build Debug inside the container; the crash usually reproduces there too.
* The e2e harness resolves the binary from the fixed path `zig-out/bin/fx` (`tests/evals/eval-helpers.ts`). To run every spawned fx under gdb, move the real binary aside and drop in a wrapper script: `exec gdb -batch -ex run -ex bt --args /work/zig-out/bin/fx.debug "$@" 2>&1`. The tests then capture the backtrace in the recorded stdout.
* A crash PC in heap range with an unwindable stack means execution jumped through a corrupted or freed pointer; on aarch64 read `$lr` and walk `$x29` manually when `bt` gives up.

### Judging local test noise

* macOS-local `zig build test` currently carries a pre-existing `terminal` test leak and an occasional `command_runner` timing flake that do not appear on CI runners. Before attributing any local failure to your diff, `git stash` and rerun on the unmodified HEAD; only deltas matter.
* Full local assurance of Full CI is impossible: it needs all four native runners and macOS x86_64 cannot run on an arm64 host. Best local coverage is the failing files on both Linux architectures in Docker plus local macOS plus `zig build test`; the authority remains Full CI on the exact pushed commit.
