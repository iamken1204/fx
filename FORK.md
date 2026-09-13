# Fork Notes

This is the `kfx` personal fork of [vercel-labs/fx](https://github.com/vercel-labs/fx) (`kfx` reads as k·f(x): upstream scaled by a personal constant). The fork branch is `kfx`, and `make install` installs the binary as `kfx` so it never shadows an upstream `fx` on PATH; the build output stays `zig-out/bin/fx` because `build.zig` is upstream code. This file exists only in the fork, so it never conflicts with upstream. Read it before rebasing onto upstream `main` or extending fork behavior, and keep the patch inventory below current.

## Features

| Feature | Enable | What it does |
| --- | --- | --- |
| Profile system prompt | Write `~/.fx/SYSTEM.md` | Replaces the compiled system prompt across TUI, `fx ask`, ACP, and subagents. `fx ask --system` still overrides it; `fx doctor` reports invalid files |
| Exclude builtin tools | `FX_EXCLUDE_TOOLS=name1,name2` | Hides the listed builtin tools from model advertisement; the registry stays full |
| Skill catalog by source | `FX_SKILL_SOURCES=claude,fx` | Advertises only skills from the listed roots (`fx`, `workspace`, `claude`, `codex`, `agents`, `opencode`, `claw`); skills with `disable-model-invocation: true` are always hidden from the model. The `/skill` menu still lists everything |
| Codex account in provider picker | Select the Codex provider | Shows the signed-in ChatGPT email beside the active Codex row in `/provider`; falls back to a masked account ID when the access token has no usable email claim |
| Multiple Codex accounts | `/login codex new`, then `/login codex <email or account id>` | Signing in with another ChatGPT account keeps the previous session in `~/.fx/chatgpt-accounts/<account_id>.json` instead of overwriting it; `/login codex <account>` swaps a stored account into the active `chatgpt-auth.json` and re-adopts the credential. An unknown account name lists what is stored |

Recommended setup:

```bash
export FX_EXCLUDE_TOOLS=vision,web_search
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

## Spec index

Statuses distinguish proposals, retained implementation records, and removed designs.

Specs live in `kfx/specs/`, one file per intent, each opening with a status line. This table is the index; keep it current. When a spec lands, add its patches to the inventory below. Keep evidence-bearing specs with an explicit status; removed designs are historical records, not implementation requirements. `idea` means a sketch worth keeping; `spec` means ready to implement.

| Spec | Status | Intent |
| --- | --- | --- |
| [de-vercel.md](kfx/specs/de-vercel.md) | idea | Keep remaining Vercel surfaces dormant through configuration; patch cosmetic exposure only if it bothers |
| [local-web-control-plane.md](kfx/specs/local-web-control-plane.md) | spec | Add a single-user loopback web UI that lists every durable local session and continues dormant or actively owned sessions through one typed control plane |
| [recoverable-session-history.md](kfx/specs/recoverable-session-history.md) | spec | Add stable locators, omission landmarks, deterministic search, and bounded exact reads for canonical turns outside the prompt horizon |
| [turn-arena-memory-growth.md](kfx/specs/turn-arena-memory-growth.md) | landed, kept | Incident record for the 2026-08-29 48 GiB kill: four retained turn-arena boundaries, their fixes, the `kfx/repro` reproductions, and the real-session curves; kept because the patch inventory alone does not carry the evidence |
| [context-budget.md](kfx/specs/context-budget.md) | mixed: active controls and historical measurements | Child usage and skill filtering remain; eviction is removed. Retains the 2026-08-29 measurements, not a comparison against the present upstream |
| [incidents/2026-09-05-sigtrap](kfx/incidents/2026-09-05-sigtrap/README.md) | open | Heap corruption trap (`memory corruption of free block`) during a persistent child turn; crash report, sessions, replay results, and a diagnostic build with frame pointers. Binaries in that directory stay untracked |
| [threshold-eviction.md](kfx/specs/threshold-eviction.md) | removed, historical only | Retains the 2026-09-01 cache-reset measurements and retired threshold design |

Prompt boundary note: recoverable-history tool observations belong in the existing non-cacheable within-turn suffix and must not create another overlay. Prompt assembly stays upstream: the retained history horizon, the ephemeral overlay, and automatic compaction are upstream behavior, and no fork patch may reattach the removed eviction projection.

The context-retention spec (raise the 8-turn history ceiling behind an environment variable and move the overlay behind durable history) was removed on 2026-09-12. Its problem statement no longer matched upstream: the `no_cache` overlay marking it planned to move is gone, and automatic compaction now selects recent context by token budget (`recentContextTarget` in `prompt_context.zig`) with a retry loop, so a larger fixed turn ceiling no longer describes what the model keeps. Any future work on the visible history horizon starts from a fresh measurement against the current upstream.

## Removed tool-result eviction (historical only)

Removed on 2026-09-06 from working HEAD `1574e82e10d568b362690fab3b270df3a329efde`. The restoration baseline is upstream `e051437fe2c452b4af1a796ad5a7e20dd64fd45c`, the merge base of that HEAD and the locally recorded `vercel/main`. No upstream update was performed. The rebased eviction patch is `2e4f9eba65c1652b6cf4cf340d8d07643bed0f28` ("Evict stale tool results by byte threshold"); the historical context-budget document entered this stack in `a6560812`. These revisions are from local Git history.

The patch addressed growth from resending accumulated tool results on every model step. It projected older results into `read_tool_result` handle stubs once a byte threshold was reached, retaining the newest N tool steps. It changed only model requests; canonical history, checkpoints, and stored results retained their text. See [context-budget.md](kfx/specs/context-budget.md) for the original session and batch measurements and [threshold-eviction.md](kfx/specs/threshold-eviction.md) for the threshold design and cache measurements.

The decision prioritizes agent correctness, instruction following, and task outcomes, followed by context amplification and growth. Result age does not establish relevance: skill instructions, code, error evidence, and subagent results may still matter. Earlier testing found that eviction removed loaded skill text from later requests. Replacing old results changes the prompt prefix, may reduce cache hits, and may cause repeated reads. Shrinking the request before the upstream pressure check may also postpone compaction. Historical measurements showed smaller requests, but did not establish better agent outcomes. Removing eviction is a design decision, not evidence that agents perform better without it.

The runtime uses the baseline upstream prompt assembly, result limits, large-result storage and retrieval, and automatic compaction. A normal preview or handle produced when a result is stored is still expected. Full skill text is not removed merely because more tool steps have elapsed; automatic compaction can still summarize it. The transient tool-call, provider-attempt, recovery-checkpoint, and compaction scratch arena fixes remain, together with the other active fork patches.

`FX_KEEP_RECENT_RESULTS` and `FX_EVICT_THRESHOLD_KB` have no effect. Users may remove old exports themselves; this change does not edit shell files, profiles, or settings. Future rebases and other features must not reconnect eviction.

If context growth becomes a problem again, measure separately: oversized individual results, repeated reads, tool/subtask counts, failed compaction, cache resets, and process memory retention. Choose a remedy from that evidence; do not restore age-based result clearing by default.

Local regression command (freshly build `./zig-out/bin/fx` first):

```sh
bun test tests/e2e/gateway-stream-lifecycle.test.ts --test-name-pattern 'legacy eviction variables|oversized result retrieval survives empty automatic'
```

The headless regression loads a complete skill, advances tool steps with the old variables set, retrieves a large result, triggers upstream automatic compaction, and continues. It inherits the existing gateway lifecycle training owner in `scripts/pgso/corpus.json`; that file still exercises common provider/runtime behavior. Fake providers prove these flows, not real agent quality or cost improvements. On 2026-09-06, the ReleaseSafe build, 28 focused Zig tests (result storage and provider-attempt copy lifetime), both fake-provider regressions (72 assertions), Zig formatting, and diff checks passed. The headless process exited 0 with only expected tool progress and the explicit yolo notice on stderr; the TUI exited normally with empty stderr and its resumed headless retrieval exited 0 with only expected progress. Full CI was not run: this work was authorized for local edits and verification only. These checks do not establish real agent quality or cost improvements.

## Maintenance strategy

The fork is a thin patch stack rebased onto upstream `main`.

* One intent per commit. Do not mix fork patches with unrelated work; each patch must be individually keepable or droppable during a rebase.
* Every fork commit carries a body explaining its intent and its conflict policy. During a rebase, read the commit body of the conflicting patch first.
* Prefer additive seams (environment variables, config, new files) over deleting or rewriting upstream code, so patches rarely conflict.
* Enable `git rerere` locally (`git config rerere.enabled true`) so a conflict resolved once replays automatically. Agents must not change git config themselves; ask the user to run it.
* Upstream hot zones that fork goals touch: `src/builtins/tools.zig`, `src/core/tooling/`, `src/gateway/`, `src/core/config/config_runtime.zig`. Expect conflicts there and resolve in favor of the patch's stated policy.

## Patch inventory

Active patches, ordered oldest first. Update this table whenever a fork patch is added, dropped, or absorbed by upstream. The retained code intents from the 2026-09-02 restack are "Load the profile system prompt" (profile prompt and its E2E), "Control model-visible capabilities" (FX_EXCLUDE_TOOLS and the skill filter), "Reclaim transient turn memory" (both arena patches, the MCP companion, and the compaction scratch), and "Checkpoint child session usage". The removed fifth intent is recorded in the historical section above. Rebased onto upstream `bbe224fe` on 2026-09-12 (226 upstream commits since `3c58c805`, including the compaction retry loop with steering boundaries, verbatim tool output, MCP rework, session titles, and helper cleanups). Conflicts affected the tool projection tests (upstream removed the read-only test helper), the ACP tool title (moved to `tool_call_presentation.zig`), the compaction scratch arena (re-scoped inside the new `compact_attempt` loop), and the gateway lifecycle E2E (both sides added tests). `dupeToolResultMemory` now also copies `tool_images`, `tool_image_handle`, and `review_feedback`; the tripwire count is 13. Backup: `kfx-backup-20260912-40b37345`.

Rebased onto upstream `4d16c835` on 2026-09-13 (30 upstream commits since the actual previous merge base, `e26e97ec`). All 13 fork commits remain. The only manual conflict was in README.md: preserve upstream's quick-start rewrite and move the profile system prompt instructions into `Extend fx`. Runtime patches applied without manual changes. Backup: `kfx-backup-20260913-9d69ba35`.

Local verification passed: `zig build`, `zig build test`, `zig fmt --check src/`, the profile-prompt E2E, and both legacy-eviction/automatic-retrieval E2Es (92 assertions across three tests). Local fake-provider captures verified tool exclusion, skill source filtering, and hidden skills; skill locations use opaque `skill:` locators with a root table. The freshly built binary completed a TTY prompt and UI exit with empty stderr. An isolated profile with fake Codex tokens also verified current email display, stored-account listing, switching by account ID and email, and opening/cancelling sign-in with an active account; stderr stayed empty. Full CI was not run and the branch was not pushed. Whitespace checks pass outside the unchanged historical incident captures.

| Patch | Intent | Conflict policy |
| --- | --- | --- |
| Add a profile system prompt at ~/.fx/SYSTEM.md | User-owned system prompt file replaces the compiled prompt across TUI, ask, ACP, and subagents; `fx ask --system` stays ahead of it; invalid files are refused and reported by `fx doctor` | Keep the profile file lookup ahead of the compiled prompt; if upstream reshapes prompt assembly, re-attach the lookup at the new assembly point. Since 2026-09-03 the `main.zig` entry configs take an `auth_mode` (host-managed authentication); `cfg` must stay `var` so the loaded prompt can be applied, and the entry-config test calls `fullEntryConfig(.local)` |
| Cover the profile system prompt in E2E | E2E assertions for the doctor report and for the profile prompt reaching the model request | Follows the patch above; update assertions rather than dropping them |
| Hide tools named in FX_EXCLUDE_TOOLS from model advertisement | Comma-separated env var hides builtin tools from the model at the shared projection choke point (`appendBuiltinTool`); vision routing is decided separately by the orchestrator, so `visionPolicy` checks the same list; registry stays full | Keep the `excludedByEnvironment` checks at the top of each filter chain if upstream rewrites `appendBuiltinTool` or the vision policy wiring |
| Reclaim tool-call and checkpoint scratch instead of retaining it in the turn arena | Gives every ordinary tool call a per-call `c_allocator`-backed arena with copy-out of survivors to the result allocator, and builds recovery-checkpoint execution memory in scratch freed on return; fixes a turn-long memory retention that grew until jetsam killed the process (upstream issue [#483](https://github.com/vercel-labs/fx/issues/483)) | Submitted upstream as [PR #484](https://github.com/vercel-labs/fx/pull/484). If it merges verbatim, rebase drops both patches automatically via patch-id; if it merges modified, drop both patches in favor of upstream. Until then expect conflicts in `src/core/tooling/` and the orchestrator hot zones |
| Keep the MCP input-required error code static past the dispatch copy-out | Assigns the static `"McpInputRequired"` after the dispatch copy-out because `PromptRunResult.error_code` is a borrowed pointer never freed by `deinit`; without this the final `fx ask --json` render reads the freed turn arena and crashes with SIGSEGV on Linux (see CI field notes below) | Inseparable companion of the patch above and part of the same upstream PR; keep or drop the two together |
| Reclaim provider-attempt scratch instead of retaining it in the turn arena | Gives each model attempt a `c_allocator`-backed arena for the request body, HTTP client, provider-state replay parse, and SSE parse trees, and deep-copies the surviving `Result` into the turn arena at `copyStreamResultToTurnArena`; the `dupeModelCompletion` tripwire fails the build when a slice-bearing field is added without extending the copy. Fixes the retention that survived the two patches above and reached 48 GiB in the 2026-08-29 incident | Third commit of [PR #484](https://github.com/vercel-labs/fx/pull/484); same drop rule as the two patches above. Conflicts land in the orchestrator attempt loop; keep the attempt arena scoped to one loop iteration and the copy-out before `break` |
| Scope in-turn context compaction to one c_allocator arena | `compactContextTransaction` in the orchestrator step loop runs on a scratch arena that dies with the compaction block instead of the turn arena, and the handoff is copied out; the promoted result copies, the compactor request body, and its stream parse otherwise stayed alive for the rest of the turn. The canonical window stays on the turn arena because the retained history tail is copied from it. Manual `/compact` already runs on its own arena in `app_agent_runtime.zig` | Keep the scratch arena around the transaction call and the `arena.dupe` on the handoff. Both `active_compaction_handoff` and the retained `compaction_history` summary must use that turn-owned copy. Recovery checkpoint projection also uses the checkpoint scratch arena. If upstream reshapes the compaction block, re-scope at the new transaction call |
| Checkpoint subagent usage on child turn commit | `LoadedWritableSession.appendUsageCheckpoint` in `session_log.zig` is the one writer of `usage_checkpointed` events; the app loop and `fx ask` call it inside their profile-recovery prepare/finish pair, and `TurnContext.commit` in `src/core/subagent/execution.zig` calls it after `appendCommittedHistory` without the marker (children have no profile ledger to recover). Before this, every child session reported zero requests. Fake Codex: child `usage-v2.json` carries the child's input tokens | The helper is additive; the two upstream call sites shrink to one line each and may conflict on rebase, resolve by keeping the helper call. Keep the child call after the history event so a failed commit never records usage |
| Filter the skill catalog by source and honor disable-model-invocation | `skill_contract.zig` parses `disable-model-invocation` through the same value parser as `name`; `skill_runtime.modelVisibleSkills` is the one projection the model sees through, applied by the prompt catalog, the `skill` tool, and `capability_search`, and it also applies `FX_SKILL_SOURCES` (comma-separated `SkillMenuSourceFilter` names, parsed once per call). Discovery and the `/skill` menu keep the full list. `fx doctor` reports `skill_sources` and fails on an unknown name. Real skill roots on this machine: 76 skills, 38 KB, 9.2K tokens before; `FX_SKILL_SOURCES=claude` gives 48 skills, 25 KB | Keep `buildSkillPrompt`, skill preparation (retained locations and fresh discovery), legacy skill loading, and capability search on `modelVisibleSkills`. Upstream moved `Skill` into `skill_contract.zig`; keep the flag there. Intentional filtering must not emit the unsafe-identity warning. If upstream adds its own `disable-model-invocation` handling, drop that half and keep the source filter |
| Show the Codex account in the provider picker | Extracts the optional namespaced profile email from the existing Codex access token without changing the saved session schema. `credentials.Credential` owns only that identity data; `provider_picker_runtime.zig` chooses email first, otherwise masks the account ID, and appends `current` in the active provider row's existing annotation column | Keep identity extraction in `chatgpt_oauth.zig`, identity ownership on `credentials.Credential`, and all masking and annotation formatting in `provider_picker_runtime.zig`. The active-provider path must stay provider-agnostic, must keep upstream's `model_provider.authorizesCredential` gate, and fixed-buffer formatting must fall back to `current` on overflow. If upstream adds provider account identity, prefer its typed field and UI instead of retaining parallel fields |
| Hold the process on SIGTRAP behind FX_HOLD_ON_TRAP | Debug knob for the 2026-09-05 heap-corruption trap: the interactive bootstrap installs a SIGTRAP handler that prints the pid and parks the faulting thread, so `malloc_history` can inspect the live process instead of a dead one; the UI keeps running. Off unless the variable is set | Additive: one handler plus one call after `installAbnormalExitHandlers` in `app_lifecycle.zig`; reattach the call if upstream reshapes the bootstrap. Drop once the corruption is found |
| Keep several Codex accounts and switch between them | `src/core/auth/chatgpt_accounts.zig` stores inactive sessions as `chatgpt-accounts/<account_id>.json` under `~/.fx`, in the unchanged v1 session schema; `saveNewSession` stashes the previous session when the account differs, and `activate` swaps a stored session into `chatgpt-auth.json` under the existing session lock. The `/login` command gains a payload (`accepts_payload` on its registry entry, `login: []const u8` in the router): `/login codex new` starts the Codex sign-in even while an account is active, `/login codex <email or account id>` activates a stored account and re-selects the `chatgpt_subscription` credential when it is live. Every other `/login` form still opens the picker, which also owns the typed `/login codex` line | Additive: one new file plus a one-line stash call in `saveNewSession`. The active session file, its schema, refresh, and `ChatGptAccountChanged` stay upstream; stored files are only read by the fork. If upstream gives `/login` a payload of its own, merge the Codex branch into its parser rather than keeping a second one. If upstream adds multi-account storage, drop this patch and migrate the stored files |

Dropped on 2026-09-02 while rebasing onto upstream `4ab76173`: "Scope subagent inspect-wait scratch to one poll" (fourth commit of PR #484) and "Raise the subagent inspect-wait ceiling to ten minutes". Upstream removed `inspect.wait` and its 100 ms poll loop; `observeManagedState` in `src/core/subagent/tool_host.zig` now blocks on `managed.wait` until a terminal phase with no per-pulse loading and no ceiling, so both patches have no code to attach to. The incident record in [turn-arena-memory-growth.md](kfx/specs/turn-arena-memory-growth.md) still describes the fourth boundary as it was.

## Verifying after a rebase

1. `zig build test` passes.
2. `zig build`, then confirm the exclusion end to end: point `FX_GATEWAY_CHAT_URL` at a local server that captures the POST body, run `FX_EXCLUDE_TOOLS=vision,web_search ./zig-out/bin/fx ask "hi"`, and check the captured `tools` array omits the excluded names while the baseline run includes them. `web_search` is advertised to the model as the gateway provider tool `exa_search`, so that is the name to look for; `vision` is only advertised when the model lacks native vision.
3. Confirm `~/.fx/SYSTEM.md` still displaces the compiled prompt (`fx doctor` reports the system_prompt check).
4. Run the focused gateway lifecycle regression for legacy eviction variables, skill retention before compaction, automatic compaction, and stored-result retrieval (see the removal record above).
5. `FX_SKILL_SOURCES=claude` against the same capture drops every `<location>` outside `~/.claude/skills`, and no skill with `disable-model-invocation: true` appears with or without the variable.
6. Run the freshly built `./zig-out/bin/fx` in a real TTY with Codex active, open `/provider`, and confirm the active row shows the profile email or masked account ID plus `current`; exit through the UI and require clean stderr.
7. In the same isolated `HOME`, drop a second v1 session file into `.fx/chatgpt-accounts/` (fake tokens are fine), then check `/login codex nope` lists it, `/login codex <its account id>` swaps the files and reports the load failure for the fake tokens, `/login codex <real email>` swaps back and prints `Switched Codex account to`, and `/login codex new` opens the Codex sign-in screen while an account is active (Esc cancels).

### Provider picker verification notes

* Find the live screen owner before editing. The setup Connections screen is rendered by `src/ui/footer/picker_presentation.zig`, but the slash-command provider rows and annotations are assembled by `src/core/app/provider_picker_runtime.zig`.
* Auth source files are not standalone Zig test roots because their imports depend on the build graph. Run their tests through `zig build test`; direct `zig test src/...` failures do not prove the changed test failed.
* Exercise this path with the freshly built `./zig-out/bin/fx` attached to a real TTY. An isolated `HOME` can carry a permission-restricted copy of `chatgpt-auth.json`; drive `/provider` through tmux, inspect the pane and stderr, exit through the UI, then delete the credential copy.

## Incident notes

### Revoked terminal spins at 100% CPU or aborts on exit (2026-09-13)

Status: reproduced, not fixed. Two `kfx` processes launched on September 5 remained alive for about eight days, each using one CPU core. Their TTY was absent and stdin, stdout, and stderr were `revoked`. Both exited on the user-authorized `SIGTERM`. The original terminal disappearance and signal delivery could not be recovered; the remaining fish parents do not establish a Ghostty bug.

The original sample's UUID, `E53F0FF6-0732-3457-AF19-DCF3C155DAA8`, matches `kfx/incidents/2026-09-05-sigtrap/kfx-diag-41d872cb.bin`. Despite that archive's name, these processes were spinning in `App.run` / `loopCollectFacts` / `poll`, not parked in the SIGTRAP handler.

Two paths depend on when the terminal becomes invalid:

* Before the next `poll()`: macOS returns `POLLNVAL`. `TerminalState.pollInput` in `src/ui/shell_runtime.zig:249-269` maps `IN`, `HUP`, and `ERR`, but drops `NVAL`. `src/ui/event_loop.zig:76-120` repeats without waiting or exiting, consuming one CPU core.
* While `poll()` is waiting: the tested path returned `input_closed`, then aborted during cleanup. `TerminalState.disableRawMode` calls `std.posix.tcsetattr` at `src/ui/shell_runtime.zig:135`; Zig 0.16 treats `EBADF` as `unreachable`. The surrounding `catch {}` cannot catch a panic.

Verification on macOS 26.5.1 arm64, Zig 0.16.0, fork `73f994d2`:

| Test | Result |
| --- | --- |
| Independent PTY revocation, then poll | 100/100 returned `POLLNVAL` (32) |
| Revoke immediately before poll, using LLDB to control timing | 3/3 runs spun at roughly 97 to 100% CPU |
| Same controlled timing on rebuilt September 5 source `41d872cb` | 1/1 spun at roughly 99.5% CPU |
| Revoke without controlling timing | 4/4 aborted; a diagnostic rebuild located the cleanup failure in `tcsetattr` |
| Send `SIGHUP` to an isolated fish running fx | Both exited |
| Close an actual Ghostty test terminal running isolated fish and fx | 3/3 exited in 5.14 to 5.17 seconds, without leftovers |

The two UI files were byte-identical to upstream `4d16c835171a0e2122efcfab98f4da2f549b6b4e`; an upstream-only binary was not tested. Ghostty was `1.3.2-main-+3c1ef5b32`, fish was `4.9.3`. That fish binary was installed after September 5, so these tests do not establish the old shell's behavior.

To reproduce the spin, build a symbolized `./zig-out/bin/fx`, give it an isolated `HOME`, and connect its input and output to a fresh PTY slave. Keep draining the master so startup output cannot block. Under LLDB, break at the `std.posix.poll` call in `TerminalState.pollInput` after startup (line 263 at the tested revisions; ignoring the first 30 hits worked). While paused before the call, invoke macOS `revoke(slave_path)` from the harness, disable the breakpoint, and continue. Observe CPU usage and the event-loop stack, then terminate and reap the test process. Do not revoke an existing user terminal. Uncontrolled timing can reproduce the cleanup abort instead of the spin.

The repair needs both `POLLNVAL` handling and cleanup that tolerates revoked descriptors. Add coverage for both timing paths; an abort is not a passing terminal-close test. Diagnostic builds need frame pointers and unwind tables for a useful cleanup backtrace. All runs used freshly built binaries without model requests; the normal `zig build` output was restored afterward.

The [investigation report](kfx/incidents/2026-09-13-revoked-terminal/FINDINGS.md) and [LLDB reproducer](kfx/incidents/2026-09-13-revoked-terminal/poll-race.py) are archived in `kfx/incidents/2026-09-13-revoked-terminal/`. The report includes usage instructions. Original transcripts (`current-controlled*-lldb.txt`, `old-controlled-lldb.txt`, and `debug-stderr.txt`) remain temporary files under `/tmp/fx-tty-investigation/`; the reproducer needs none of them. This is a manual diagnostic harness, not a CI regression test. All test processes and added Ghostty terminals were cleaned up. For Ghostty automation, identify the newly added terminal by its unique ID: `new window` can return a tab-group window containing existing terminals, so its first terminal need not be the one just created.

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
