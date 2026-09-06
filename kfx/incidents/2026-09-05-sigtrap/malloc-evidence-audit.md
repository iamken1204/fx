# Malloc Evidence Audit

## Conclusion

The `malloc_history` `ALLOC` rows captured from the held process do not describe
the allocation requests that were trapping. With `MallocStackLogging=lite`, the
MallocStackLogging wrapper calls the underlying zone allocator first and records
the new pointer's stack only after that call returns. All three threads were
stopped inside `_xzm_xzone_malloc_freelist_outlined`, before that return.

The reported stacks are best treated as residual metadata from an earlier
successful allocation of the selected storage. They can suggest an earlier
allocation call site while the stack-table entry remains decodable. They do not
prove who still owned the block, who freed it, who damaged the free-list
metadata, or whether that earlier caller was involved in the corruption. They
are not a durable allocation-history record: lite mode releases the stack-table
reference during `free`, while leaving the in-block payload in place.

The three addresses do not establish propagation after a first trap. They are in
one 16 KiB interval, but they are not adjacent 32-byte blocks, and the evidence
does not establish a trap order. The held process also continued after every
fatal allocator invariant. Because xzone commits its free-list pop before it
validates the selected block, later traps may be secondary observations of a
free list already mutated by an earlier trapping pop. They may instead be
independent discoveries of multiple corrupt blocks. The captures cannot choose
between those explanations.

## Incident Cross-Check

The saved context resolves the actual PC for each thread to
`_xzm_xzone_malloc_freelist_outlined +856`, the `brk #1` instruction, rather
than to MallocStackLogging. The ordinary backtrace displays
`stack_logging_lite_malloc +108` because that is the link-register return
address to which xzone would have returned. The incident README records this
distinction at [held-65259/README.md:8](held-65259/README.md#L8), and the
instruction is resolved and disassembled at
[held-65259/lldb-trap-instruction.txt:13](held-65259/lldb-trap-instruction.txt#L13)
and [held-65259/lldb-trap-instruction.txt:35](held-65259/lldb-trap-instruction.txt#L35).

The UI thread is the decisive internal control. Its current request comes from
terminal painting, below `stack_logging_lite_malloc +108` in the live stack at
[held-65259/lldb-initial.txt:19](held-65259/lldb-initial.txt#L19). Yet
`malloc_history` attributes the selected address `0x76b02c1c0` to an earlier
`dupeToolCall` allocation at
[held-65259/malloc-history-other.txt:2](held-65259/malloc-history-other.txt#L2).
Those cannot be the same request. The wrapper had not returned from the UI
request and therefore could not have logged it.

For the child address `0x76b02ed20`, the decoded history and current request
both pass through `onStreamToolStart`; compare
[held-65259/malloc-history.txt:2](held-65259/malloc-history.txt#L2) with
[held-65259/lldb-initial.txt:122](held-65259/lldb-initial.txt#L122). That match
does not change the ordering proof. It is consistent with the same call site
having allocated the storage in an earlier lifetime. The parent address
`0x76b02f1f0` has no decodable stack log at
[held-65259/malloc-history-other.txt:4](held-65259/malloc-history-other.txt#L4).

The current payload at `0x76b02ed20` begins with `read_file`, as shown at
[held-65259/lldb-trap-instruction.txt:42](held-65259/lldb-trap-instruction.txt#L42).
That is useful as evidence that old user bytes remain in the selected block. It
does not identify the write that broke the authenticated free-list linkage.

## What Lite Mode Records

The installed `malloc(3)` manual says that `MallocStackLogging=1`, the default
form, is the lite mode. It records stack traces for currently allocated memory,
without allocation history, in memory. Full mode instead records both
allocation and deallocation events. The exact installed text is at:

`/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/usr/share/man/man3/malloc.3:240-249`

The installed `malloc_history(1)` manual describes address mode as printing the
allocation and deallocation records available for an address, but that general
description does not turn lite mode into an event log. The relevant text is at:

`/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/usr/share/man/man1/malloc_history.1:45-54`

`/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/usr/share/man/man1/malloc_history.1:75-80`

The installed `malloc_history` binary contains the corresponding diagnostic:

> Can't report high water mark because full stack history is not available,
> only allocation backtraces of live allocations.

That string can be reproduced locally with:

```sh
strings /usr/bin/malloc_history | rg 'only allocation backtraces of live allocations'
```

The incident's deliberate full-mode probe shows the contrast directly: it has
an `ALLOC` followed by a `FREE` for the same address at
[held-65259/full-mode-history.txt:2](held-65259/full-mode-history.txt#L2). A
normal lite-mode process queried after freeing its probe allocation returned no
stack logs for the freed address. This is why a lite `ALLOC` row is normally a
live-allocation snapshot rather than retained history.

## Wrapper Ordering

Disassembly of the exact installed MallocStackLogging image loaded by the held
process shows this order in `stack_logging_lite_malloc`:

```text
stack_logging_lite_malloc +104: blraa x8, x17     ; call helper-zone malloc
stack_logging_lite_malloc +108: mov   x21, x0     ; first instruction on return
stack_logging_lite_malloc +112: cbz   x0, ...
...
stack_logging_lite_malloc +136: bl    add_stack_to_ptr
```

The loaded image is version 65000 with UUID
`782A39D3-C9FD-3E0B-B8FB-26E5D749BE57`, recorded at
[held-65259/sample-original.txt:432](held-65259/sample-original.txt#L432). The
disassembly can be reproduced without attaching to the held process:

```sh
dyld_info -arch arm64e -disassemble \
  /System/Library/PrivateFrameworks/MallocStackLogging.framework/Versions/A/MallocStackLogging \
  | sed -n '2615,2740p'
```

Thus a trap in the underlying xzone call occurs before `add_stack_to_ptr`. No
stack for the pending request has been attached to the pointer.

The same installed disassembly shows that `stack_logging_lite_free` reads the
payload near the end of the block and calls
`uniquing_table_stack_release` before it tail-calls the helper-zone `free`. It
does not clear that payload first. The pointer-to-payload helper obtains it from
the final eight bytes of the zone-reported allocation size. This explains how
old stack metadata can remain in a block that xzone is currently removing from
a free list, even though lite mode no longer retains that allocation as an
event. Because the stack-table reference was released, a surviving payload may
also be stale or no longer reliably identify the original stack.

Apple's current public libmalloc source independently shows the ordinary logger
ordering: the zone allocation happens before the logger callback in
[`malloc.c:1999-2005`](https://github.com/apple-oss-distributions/libmalloc/blob/libmalloc-792.1.1/src/malloc.c#L1999-L2005).
No matching Apple source checkout was present locally. The public tag is useful
corroboration; the installed-image disassembly above is authoritative for this
capture.

## Why A Mid-Pop Block Can Look Live

Apple's public xzone source performs the free-list update before validating the
selected block's cookie and authenticated next-link:

1. It reads the candidate and next-link metadata, then computes a replacement
   free-list head at
   [`xzone_malloc.c:1702-1721`](https://github.com/apple-oss-distributions/libmalloc/blob/libmalloc-792.1.1/src/xzone_malloc/xzone_malloc.c#L1702-L1721).
2. It commits the new metadata with a compare-and-swap and leaves the retry loop
   at
   [`xzone_malloc.c:1737-1756`](https://github.com/apple-oss-distributions/libmalloc/blob/libmalloc-792.1.1/src/xzone_malloc/xzone_malloc.c#L1737-L1756).
3. Only afterward does it validate the cookie and link and set the corruption
   result at
   [`xzone_malloc.c:1775-1805`](https://github.com/apple-oss-distributions/libmalloc/blob/libmalloc-792.1.1/src/xzone_malloc/xzone_malloc.c#L1775-L1805).
4. The wrapper reports the corrupt block at
   [`xzone_malloc.c:1815-1827`](https://github.com/apple-oss-distributions/libmalloc/blob/libmalloc-792.1.1/src/xzone_malloc/xzone_malloc.c#L1815-L1827),
   and the outlined path calls the fatal corruption handler at
   [`xzone_malloc.c:2528-2536`](https://github.com/apple-oss-distributions/libmalloc/blob/libmalloc-792.1.1/src/xzone_malloc/xzone_malloc.c#L2528-L2536).

The installed `libsystem_malloc.dylib` disassembly has the same critical order:
candidate/link reads, metadata compare-and-swap, cookie/link validation, then a
tail branch to `_xzm_xzone_malloc_freelist_outlined` with a nonzero corrupt
block argument. It can be inspected locally with:

```sh
dyld_info -arch arm64e -disassemble /usr/lib/system/libsystem_malloc.dylib \
  | sed -n '48735,49105p'
```

The held-process disassembly also shows that the outlined function branches to
the fatal path when the corrupt-block register is nonzero at
[held-65259/lldb-xzone-prefix.txt:14](held-65259/lldb-xzone-prefix.txt#L14), and
the annotation and trap appear at
[held-65259/lldb-xzone-freelist.txt:152](held-65259/lldb-xzone-freelist.txt#L152).

At the trap, xzone may therefore have already made the candidate look allocated
to a live-allocation enumerator even though the allocation has not returned to
MallocStackLogging or to the application. `malloc_history` can then encounter
that candidate and decode the old in-block lite payload. The word `ALLOC` in
this state is a snapshot classification produced while the allocator is parked
mid-operation. It is not a new event record for the request on the thread's
stack.

## Address And Chronology Limits

The addresses sort as follows:

| Address | Distance From Previous |
| --- | ---: |
| `0x76b02c1c0` | n/a |
| `0x76b02ed20` | `0x2b60` (11,104 bytes) |
| `0x76b02f1f0` | `0x4d0` (1,232 bytes) |

They all fall in `[0x76b02c000, 0x76b030000)`, as the README notes at
[held-65259/README.md:37](held-65259/README.md#L37). They are aligned, but they
are not adjacent 32-byte blocks. Spatial proximity alone supplies neither a
common writer nor an order of corruption.

The stderr record contains three identical fatal messages and no address or
timestamp at [held-65259/trap.err:2](held-65259/trap.err#L2). The shared
annotation reports only its latest value, `0x76b02ed20`, at
[held-65259/lldb-annotation.txt:13](held-65259/lldb-annotation.txt#L13). It
cannot establish which thread trapped first.

The handler parked each trapping thread instead of ending the process. Other
threads continued allocating. Since the free-list pop is committed before
validation, observations after the first held trap are not independent samples
of untouched allocator state. A corrupt next link used by one pop may affect a
later head, but the evidence does not show that this occurred. Conversely,
several pre-corrupted free blocks may be discovered separately. The current
request never received the selected pointer, so its caller could not have
propagated corruption by using that new allocation.

## Ownership Implications

The statement in [ownership-audit.md:21](ownership-audit.md#L21) that an
allocation/free stack identifies an owner is sound only for a coherent lifetime
record, such as full-mode history with a matching allocation and free. It is
too broad for these held lite-mode rows.

For this capture:

- `dupeToolCall` and `onStreamToolStart` are candidate earlier allocation sites
  for reused storage, subject to stale stack-table metadata.
- Neither stack is the logging of the pending allocation request.
- Neither stack proves continuing ownership, the freeing call site, or the
  corrupting write.
- The parent block's missing history is equally compatible with unavailable,
  released, or undecodable lite metadata.
- The three held traps prove that three allocation attempts detected fatal
  free-list inconsistency while the process was allowed to continue. They do
  not prove a three-step propagation chain.

Attribution would require a clean run that stops on the first xzone trap,
preferably with full uncompacted stack history, plus a watchpoint or equivalent
evidence covering the metadata write. The existing held process is valuable for
allocator-state inspection, but continuing after a fatal invariant makes later
state unsuitable for ordering the original corruption.
