# 2026-09-05 kfx SIGTRAP evidence

Crash of `~/.local/bin/kfx` (kfx `a12e1c6e`, UUID 4B28D42B, built 08:12, installed 08:14:56) at 08:18:57 +0800.
Not an OOM: libmalloc reported `BUG IN CLIENT OF LIBMALLOC: memory corruption of free block`, MALLOC 60 MB.

Files:
- `kfx-2026-09-05-081901.ips`: macOS crash report (thread 12 in malloc, 14 threads).
- `sessions/m3uV9UuSv23X`: parent session (eviction-removal task, blocked in `subagent message`).
- `sessions/ZiigI8Cc2pQL`: persistent child `context-tests`; ran skill 08:18:44, parallel read/grep/glob 08:18:49, then request 2.
- `usage-window.jsonl`: usage ledger lines from the same minute.
- `kfx-a12e1c6e-4b28d42b.bin`: the exact crashed binary (stripped). Do not commit.
- `settings.json`: fx settings at crash time. Fish env: FX_KEEP_RECENT_RESULTS=4, FX_SKILL_SOURCES=claude, FX_EXCLUDE_TOOLS set.

## Replay results (2026-09-05)

The parent's 13 recorded steps plus the `subagent message` and the child's skill + parallel read/grep/glob batch were replayed through `kfx/repro` (`make-replay.py`, `run-persist.sh`, `run-persist-tui.sh`) against a fake Codex, on unstripped ReleaseSafe builds of the fork commit `a12e1c6e` and its upstream merge base `e051437f`:

| Run | fork | upstream |
| --- | --- | --- |
| headless, libgmalloc | clean | clean |
| headless, libgmalloc, 12 extra parent steps, eviction env | clean | clean |
| TUI in tmux, libgmalloc | clean | clean |
| TUI, paced streams (8 s per response), plain xzone malloc, 4 rounds | clean x4 | clean x4 |

Under libgmalloc the `shell` tool fails (`InvalidForegroundSessionReady`, the terminal host does not survive the inserted library), so the shell output path was only covered by the plain runs. Nothing reproduced; the writer of the corrupted free block is still unknown.

Why the crash report had no callers: upstream `build.zig` builds with `omit_frame_pointer = true`, `unwind_tables = .none`, and strips non-Debug binaries. `kfx-diag-41d872cb.bin` is kfx HEAD `41d872cb` built ReleaseSafe with frame pointers, sync unwind tables, and symbols (UUID E53F0FF6). Run it as the daily `kfx` until the trap recurs; the next `.ips` will then carry the full stack of the thread that hit the corrupted block. Install it only while no `kfx` is running: copying over the live inode makes the next launch fail signature validation and die with SIGKILL, so write a new file and rename it into place: `cp kfx-diag-41d872cb.bin ~/.local/bin/kfx.new && mv ~/.local/bin/kfx.new ~/.local/bin/kfx`.

Static audit note: in the fork's per-call arena, `ToolExecutionResult.command_result_json` for the `shell` tool is built on the call allocator (`shell.zig` `publishSnapshotMetadata`) and is not part of the copy-out in `executeRegisteredTool`. Today its only reader, `finishExecutedToolStatus`, runs inside the same call arena scope in the orchestrator, so nothing dereferences it after the free; the field is a latent hazard for any change that keeps the result past the call, not a live bug. Every other field the copy-out skips is either a plain value (`web_search_completion`, `web_fetch_completion`) or already duplicated by its sink on the result allocator (`context_notices`, `selected_dynamic_tool_*`).

## Register-dumping hold handler (commit 0d5cfddf)

`kfx-diag-0d5cfddf.bin` (UUID 99FC56A8) replaces the lldb step entirely. The `FX_HOLD_ON_TRAP` handler now takes `SA_SIGINFO`, reads x0 through x4, lr, and pc from the signal mcontext, and prints them before parking the thread, because the corrupted-block address libmalloc computes never reaches stderr, the unified log, or (in a held process) the crash reporter annotation. It only lives in the registers at the `brk`.

Confirmed live: attaching lldb to a held process showed every trapped thread inside an innocent `malloc` (transcript paint, `session_discovery.classifyReadOnlyCandidate`, `assistant_stream.onStreamToolStart`), each on a different thread and zone, all faulting on the same poisoned freelist in the shared c_allocator zone. That is the detection site; the writer ran earlier.

Capture path:

```sh
env FX_HOLD_ON_TRAP=1 MallocStackLogging=1 kfx 2>> ~/kfx-trap.err
# when a subagent freezes, read the held line:
tail -3 ~/kfx-trap.err        # x0..x4, lr, pc; one x register is a heap address
malloc_history <pid> <that heap address>
```

`malloc_history` prints the alloc and free stacks of that block. If the free stack is one of the fork's `c_allocator` arenas (per-call in `tool_runtime`/`parallel_execution`, per-attempt in the orchestrator, or the compaction scratch), the writer is fork code; if it is a turn-arena or an upstream path, it is upstream. That is the test that settles fork versus upstream.

## Third crash, diagnostic build (20:52:07)

`kfx-2026-09-05-205212.ips`, binary `kfx-diag-41d872cb.bin` (UUID E53F0FF6), sessions in `sessions-2052/` (parent `VD28f0Uop27m`, persistent child `AuArpYch32kJ`). Same libmalloc trap, 56 MB allocated. The child's third request checkpoint was written at 20:52:07 and the trap fired at 20:52:07.79, so the crash is the DNS lookup of that request. With frame pointers the faulting thread reads:

```
_xzm_xzone_malloc_freelist_outlined      libsystem_malloc
si_list_concat / si_addrinfo_list_from_hostent / mdns_addrinfo / getaddrinfo   libsystem_info
Io.Threaded.netLookup                    kfx (std Io.async future on its own thread)
```

Other threads: the child's agent thread waits in `openai_codex.streamPrepared` on the bounded connect `Select`; the request task waits in `http.Client.connectTcpOptions` for the lookup queue; the deadline and cancel watchers sleep; the parent is blocked in `tool_host.Runtime.executeManaged`. Nothing was being cancelled: the lookup thread is a fresh pthread whose first small malloc pulled a poisoned block off the shared freelist. The writer ran earlier, on some other thread. The freed block addresses libmalloc reported were 0xc11436840, 0xbecc7bc80, and 0xa14c91620 across the three crashes.

Ruled out by reading: `runBoundedHttpOperation` drains and joins every Select task on all exits; `GatewayCancelWatcher` threads are joined by `defer` in the same scope; `HostName.connect` cancels and awaits its lookup future, and `Io.Threaded.cancel` waits for the task with signaling. The 30 s connect deadline is upstream since the initial commit.

Next capture, without a debugger (lldb attached to the TUI got in the way): the fork commit 84f12b2d adds `FX_HOLD_ON_TRAP`. When set, a SIGTRAP parks the faulting thread and prints the pid to stderr while the UI and every other thread keep running, so the process stays alive for `malloc_history`. `kfx-diag-84f12b2d.bin` is that commit built with frame pointers and symbols. Launch it with stderr to a file, since libmalloc prints the corrupted block's address there before trapping:

```sh
env FX_HOLD_ON_TRAP=1 MallocStackLogging=1 kfx 2>> ~/kfx-trap.err
# when the TUI freezes a subagent or you see the held message:
tail -5 ~/kfx-trap.err              # "BUG IN CLIENT OF LIBMALLOC ... <address>" and "SIGTRAP held ... pid N"
malloc_history <pid> <address>      # who allocated and who freed the poisoned block
sample <pid> 1 -file ~/kfx-trap-sample.txt   # every thread's stack, symbolized
```

The free stack in `malloc_history` names the owner of the block (turn arena, attempt arena, per-call arena, or something outside the fork), which settles whether the writer is fork or upstream code.
