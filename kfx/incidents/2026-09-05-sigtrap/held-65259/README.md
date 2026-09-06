# Held process investigation, 2026-09-05

Research remains open. No production fix has been made. Source checkpoint:
`5b5dc8ad`. Continued Claude session `7ec4afbd-76ab-41e3-bbfc-7ff1612a2cf1`.

## Confirmed evidence

The process 65259 was still alive. LLDB inspections were read-only and detached
after collection. Three threads were parked in `holdOnTrapHandler`: the UI,
parent, and child. Therefore the earlier promise that the UI remains usable
after a held trap does not hold when the UI also encounters corruption.

LLDB's ordinary backtrace omitted the actual malloc leaf frame. Its apparent
`stack_logging_lite_malloc + 108` PC is a return address, not the trap. The
signal ucontext retained the actual PC `0x1884f1990`, identified and disassembled
as `_xzm_xzone_malloc_freelist_outlined + 856`, `brk #1`.
See `lldb-context.txt`, `lldb-fault.txt`, and `lldb-trap-instruction.txt`.

`libsystem_malloc.__DATA.__crash_info` at `0x1f1d8f578` held the message pointer
at offset 8 and the latest corrupted address at offset 56. The message is
`BUG IN CLIENT OF LIBMALLOC: memory corruption of free block`.
It is not emitted to stderr on this observed path. The disassembly stores the
message and address directly before trapping. See `lldb-annotation.txt`.

Recover each thread's own address from saved x4, rather than assuming the
shared crash annotation still describes the first trap. `_sigtramp` keeps
ucontext in x20; the local arm64 SDK places its mcontext pointer at offset 48.
The exception state occupies 16 bytes, then x0 through x28, fp, lr, sp, pc.
See `lldb-other-ucontexts.txt` and `lldb-other-registers.txt`.

| Thread | Corrupted address (saved x4) | Allocation evidence |
| --- | --- | --- |
| UI | `0x76b02c1c0` | Child recovery checkpoint duplication, `dupeToolCall` |
| Parent | `0x76b02f1f0` | No stack log found |
| Child | `0x76b02ed20` | `onStreamToolStart`, provisional tool status allocation |

The child block starts with ASCII `read_file`. All three addresses lie in the
same 16 KiB interval. This does not prove a common writer or that any allocation
stack is itself responsible for corruption. Logs report 32-byte allocations
for the two recognized addresses. See `malloc-history.txt` and
`malloc-history-other.txt`.

## Why the free history is missing

The installed macOS SDK's `usr/share/man/man3/malloc.3`, lines 240-260, explicitly
documents `MallocStackLogging=1` as **lite**, retaining current allocation
stacks without history. `MallocStackLoggingNoCompact=1` implies full mode and
preserves adjacent allocation/free pairs. The earlier capture recipe therefore
cannot provide the promised free history. The older `malloc_history` manual
describes different defaults; prefer the installed malloc manual and an actual
probe. Apple's [memory profiling presentation](https://developer.apple.com/videos/play/wwdc2022/10106/)
also distinguishes live-only lite mode from full allocation/deallocation logs.

Validated locally with a small C program that allocates, frees, and sleeps:
`env -u MallocStackLogging MallocStackLoggingNoCompact=1 /tmp/kfx-stack-history-probe`.
`full-mode-history.txt` contains both ALLOC and FREE stacks for that same
address, including source lines. The probe exited normally after 45 seconds.

For the next real capture, start a newly built diagnostic binary with
`MallocStackLogging` removed and `MallocStackLoggingNoCompact=1`, plus
`FX_HOLD_ON_TRAP=1`. Use this checkout's `./zig-out/bin/fx`. Preserve stderr,
but collect the address from the saved signal context / crash annotation if
stderr only contains the hold message. Do not restart or terminate the existing
held process until its evidence is no longer needed. History cannot be recovered
retroactively from this lite-mode run.

## Source audit and remaining work

See [ownership audit](../ownership-audit.md). Provider operations cancel and
join before their arena is freed; no concrete writer was established there.
The provisional status methods separate their persistent allocator from render
scratch; inspected orchestrator calls pass `stream_ctx.alloc` for status storage.
The `recordTracked` name allocation and cleanup are also present in upstream
`e051437f`. An allocation stack alone cannot attribute the defect to fork or
upstream. A full-mode free stack, or a deterministic failing reproduction, is
still required to narrow that attribution.

`zig build -Doptimize=ReleaseSafe` succeeded during this continuation. This is
research evidence, not a claim of a repaired or ship-ready binary. No Full CI
run or product fix was performed. Background source inspection was interrupted
by a platform content block, including after the user reported Daybreak approval.
