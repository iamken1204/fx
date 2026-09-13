# Revoked terminal investigation, 2026-09-13

## Conclusions

The high-CPU failure is reproducible in fx without Ghostty or fish. Terminal revocation just before the next poll causes POLLNVAL, which TerminalState.pollInput ignores. The event loop keeps collecting facts and polling an invalid descriptor at roughly one CPU core.

Revocation while poll is already waiting can take a different path: the event loop returns input_closed, then terminal cleanup calls tcsetattr on the revoked descriptor. Zig treats EBADF as unreachable and aborts. An initial test that aborted did not disprove the spin bug; the timing differed.

The original terminal disappearance and signal delivery on September 5 remain unknown. Normal closure in the installed Ghostty did not leak processes in the tests below. This does not establish that Ghostty could never have contributed to the original incident.

## Original processes

- kfx PIDs 54992 and 55906 started September 5 at 21:01:17 and 21:02:27.
- Both had revoked stdin/stdout/stderr, no controlling TTY, and used about 99% CPU after eight days.
- Their fish parents, 54711 and 55568, had PPID 1.
- Original sample UUID E53F0FF6-0732-3457-AF19-DCF3C155DAA8 matches the retained kfx-diag-41d872cb.bin.
- User-authorized SIGTERM stopped both kfx processes. Their fish parents were also gone at the next investigation; no signal was sent directly to those fish processes.

## Runtime evidence

All fx experiments used freshly built binaries, isolated HOME directories, and no model requests.

| Experiment | Result |
| --- | --- |
| 100 independent PTY revocations, poll afterward | 100/100 returned POLLNVAL = 32 |
| Current source, normal-timing revoke | 4/4 aborted; diagnostic rebuild located tcsetattr EBADF during cleanup |
| Current source, LLDB stops immediately before poll, revoke, continue | 3/3 spun at roughly 97–100% CPU |
| September 5 source 41d872cb rebuilt in a temporary source snapshot, same controlled timing | 1/1 spun at roughly 99.5% CPU |
| SIGHUP to an isolated interactive fish running current fx | Both fish and fx exited |
| Installed Ghostty, isolated fish, launch current fx, close exact new terminal ID | 3/3 exited without leftovers in 5.14–5.17 seconds |

The current controlled-spin stack contains App.run -> event_loop.run -> loopCollectFacts -> collectThemeFacts -> getenv, matching the original samples' hot path.

The current diagnostic binary added frame pointers, unwind tables, and error tracing via compiler flags, without source edits. A normal zig build restored the checkout's usual build afterward. The source snapshot at old-41d872cb was created with git archive, not by changing the user's branch.

## Code ownership

- src/ui/shell_runtime.zig:249–269 maps POLLIN, POLLHUP, and POLLERR, but not POLLNVAL.
- src/ui/event_loop.zig:76–120 exits on closed input but otherwise repeats collection and polling.
- src/ui/shell_runtime.zig:135 calls std.posix.tcsetattr during disableRawMode.
- Zig 0.16 std/posix.zig:1182 treats tcsetattr EBADF as unreachable.
- src/core/app/app_lifecycle.zig:52–99 installs handlers that restore terminal bytes and re-raise SIGHUP/SIGTERM with their default disposition.
- git diff vercel/main -- src/ui/shell_runtime.zig src/ui/event_loop.zig was empty at HEAD 73f994d2.

The repair should handle POLLNVAL as closed input and make raw-mode cleanup tolerate an invalid/revoked descriptor. Handling only POLLNVAL would leave the cleanup abort.

## Ghostty and fish

Installed Ghostty reports 1.3.2-main-+3c1ef5b32. Its matching Exec.zig source sends SIGHUP to its child process group and waits for the direct child. On this machine the actual hierarchy includes /usr/bin/login -> fish -> fx, with separate process groups. Testing that hierarchy through the real Ghostty application is more informative than assuming fish directly belongs to Ghostty's group.

Installed fish 4.9.3 handles untrapped SIGHUP by requesting exit. The installed fish binary dates from September 9, after the original process launch; it cannot prove the exact September 5 fish version's behavior.

The first Ghostty automation attempt exposed an identity trap: new window returned an existing tab-group window containing older terminals. Selecting its first terminal mistakenly sent ./zig-out/bin/fx to an old idle tab. That tab had no fx child when checked and was not closed. Subsequent tests identified the unique newly added terminal ID before input or closure. All new test terminals and child processes were cleaned up; existing terminals were not closed.

## Run the archived reproducer

On macOS, with Python 3 and LLDB installed, run from the repository root:

```bash
zig build -Doptimize=Debug
python3 kfx/incidents/2026-09-13-revoked-terminal/poll-race.py \
  ./zig-out/bin/fx 263 archived-repro
```

The arguments are the binary path, the source line of the `std.posix.poll` call in `TerminalState.pollInput`, and a label for the output files. Line 263 applies to the investigated revisions; check it before testing a later revision. Use a filename-safe label without spaces or slashes.

The script creates its own PTY and temporary `HOME`, drains terminal output, and pauses before poll after ignoring 30 breakpoint hits. It revokes only that PTY, resumes fx, samples CPU usage for three seconds, then sends SIGTERM. LLDB records a backtrace and kills the test process. The script creates `/tmp/fx-tty-investigation/` for generated `<label>-lldb.txt` and `<label>-stderr.txt`; it does not require the original temporary files.

This is a manual diagnostic harness, not a CI assertion. Its exit status alone does not prove reproduction: check for `REVOKE_RESULT 0`, sustained high `CPU_SAMPLE` readings, and the event-loop stack. If the breakpoint is never reached, the harness can wait indefinitely. Frame pointers and unwind tables, disabled by the normal build, are needed for a full backtrace; the spin can still be observed with the normal Debug binary.

## Archived and temporary files

This directory contains the report and [poll-race.py](poll-race.py). The following original artifacts remain only under `/tmp/fx-tty-investigation/` and may disappear when temporary storage is cleaned:

- `current-controlled-lldb.txt`, `current-controlled-2-lldb.txt`, `current-controlled-3-lldb.txt`: current-source spin evidence.
- `old-controlled-lldb.txt`: rebuilt September 5 source spin evidence.
- `debug-stderr.txt`: full cleanup-abort stack.
- `ghostty-Exec.zig` and `ghostty-pty.zig`: source at the installed Ghostty revision.
- `fish-signal.rs`, `fish-proc.rs`, `fish-reader.rs`: source for installed fish 4.9.3.

No product source or profile configuration was changed during the investigation. No Full CI was run.
