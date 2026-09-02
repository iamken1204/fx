# Turn-arena memory reproduction

Offline harness for [`../specs/turn-arena-memory-growth.md`](../specs/turn-arena-memory-growth.md). No network, no real credentials: a fake OpenAI Codex Responses SSE endpoint drives a real `fx` through a long single turn while memory is sampled.

Build `fx` first (`zig build` in the repo root, output `zig-out/bin/fx`), then:

```sh
# headless `fx ask`, 40 read steps, small reasoning, 20 KB tool results
STEPS=40 sh run.sh scale40

# isolate the streaming path: one step, 90k reasoning deltas
STEPS=0 DELTAS=90000 sh run.sh one90k

# same read load through the real TUI under tmux
STEPS=40 sh run-tui.sh tui40

# incident-shaped workload: one grep_files over the real fx repo per step,
# headless, MallocStackLogging enabled for live malloc_history attribution
STEPS=50 sh run-grep.sh grep50
STEPS=300 PACE_MS=4 PACE_EVERY=100 sh run-grep.sh grep300   # paced, minutes-long

# incident topology: parent spawns 3 one-off subagents (threads in the same
# PID), each running CHILD_STEPS grep steps; parent must outlast the children
# because headless ask exits when the parent turn ends
CHILDREN=3 CHILD_STEPS=100 STEPS=105 PACE_MS=4 PACE_EVERY=100 sh run-grep.sh subagents100

# incident parent behaviour: after spawning, the parent waits on each child
# with `subagent inspect` + wait (up to 60 s per call) before its own steps;
# paced responses keep the children alive for minutes so the wait loop polls
INSPECT_WAIT=2 CHILDREN=3 CHILD_STEPS=30 STEPS=45 PACE_MS=100 PACE_EVERY=50 sh run-grep.sh inspect-wait

# bounded 429 retry: every 10th step of each session gets one HTTP 429 first
RATE_LIMIT_EVERY=10 STEPS=50 sh run-grep.sh grep50-429

# genuine network-flap injection through the TUI: a raw TCP proxy terminates
# every odd /chatgpt/responses connection after CUT_BYTES (default 128 KiB),
# so fx sees a real mid-stream ReadFailed and its bounded retry/pause behavior
# can be regression-checked
sh run-flap.sh flap300
```

Knobs (env): `STEPS` (tool-call steps before the final answer), `TOOL` (`read_file` default, `grep_files` for repo searches), `DELTAS` / `DELTA_BYTES` (reasoning streamed per step), `ENC_BYTES` (encrypted-reasoning provider-state blob per step), `PACE_MS` / `PACE_EVERY` (stream pacing), `FLAP` / `CUT_BYTES` (mid-stream connection cuts), `CHILDREN` / `CHILD_STEPS` (one-off subagents spawned by the parent's first response; sessions are told apart by a `CHILD-TASK-n` marker in the child prompt), `INSPECT_WAIT` (inspect-wait calls the parent issues per child before its own steps), `RATE_LIMIT_EVERY` (one 429 before every Nth step of each session), `DUMP=1` (write every request body next to the server log), `FIXTURE_KB` (tool-result size for read workloads), `SAMPLE` (sample seconds), `FX_BIN`.

Each run writes to `out/<label>/`: `mem.csv` (t_s,rss_mb,vsz_mb,threads,footprint_mb), `server.log`, `fx.out` or `pane-*.txt`, `fx.err`, `trace.log` (grep/flap runs), `fx.pid`. `out/` is gitignored.

- `fake-codex.ts`: the fake endpoint (Bun), plus the raw TCP flap proxy.
- `run.sh`: isolated `HOME` + seeded fake ChatGPT JWT, runs `fx ask`, samples RSS.
- `run-tui.sh`: same, but drives the interactive TUI in tmux.
- `run-grep.sh`: headless grep workload over the real repo, stack logging and trace log enabled.
- `run-flap.sh`: TUI plus flap proxy, stack logging enabled.
- `memwatch.sh`: RSS and footprint sampler.

Live attribution while a run is going (pid in `out/<label>/fx.pid`):

```sh
footprint $(cat out/grep300/fx.pid)                    # phys footprint, the metric jetsam uses
vmmap -summary $(cat out/grep300/fx.pid)               # MALLOC_LARGE = turn-arena chunks
malloc_history $(cat out/grep300/fx.pid) -allBySize    # needs MallocStackLogging at launch
```

Caveat: RSS understates and can even fall once macOS compresses the arena's write-once pages (observed: RSS dropped from 835 MB to 610 MB while phys footprint climbed past 1.9 GB), so `mem.csv` also samples `footprint`. Footprint in turn overstates live memory: malloc keeps freed large chunks as dirty pages (`MALLOC_LARGE (empty)` in `vmmap -summary`), so a bounded workload still shows a slowly rising footprint. To separate live from retained-free memory, compare the non-empty `MALLOC_LARGE` row across `vmmap` samples, or read the live byte total from `malloc_history -allBySize`.
