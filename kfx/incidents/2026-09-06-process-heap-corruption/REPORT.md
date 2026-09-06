# Process Heap 崩潰 RCA 交接

  ## 遇到的問題（現象）

  kfx 在 macOS arm64 執行長時間、多執行緒 agent 工作時，偶發遭 SIGTRAP 終止。

  macOS libmalloc 回報：

  BUG IN CLIENT OF LIBMALLOC: memory corruption of free block

  這不是 OOM。程序當時只配置約 56–60 MB，實際原因是 allocator 從 free list 取出 block 時，發現 block 內的 cookie 或鏈
  結資訊已遭破壞。

  已觀察到三次事故：

   時間                崩潰位置                               說明
  ━━━━━━━━━━━━━━━━━━  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
   2026-09-05 08:18    _xzm_xzone_malloc_freelist_outlined    stripped binary，缺少完整 caller stack
  ──────────────────  ─────────────────────────────────────  ────────────────────────────────────────
   2026-09-05 09:59    _xzm_xzone_malloc_freelist_outlined    與第一次相同
  ──────────────────  ─────────────────────────────────────  ────────────────────────────────────────
   2026-09-05 20:52    DNS getaddrinfo 執行緒中的 malloc      diagnostic binary 有完整 stack

  第三次的 stack：

  _xzm_xzone_malloc_freelist_outlined
  si_list_concat
  si_addrinfo_list_from_hostent
  mdns_addrinfo
  getaddrinfo
  Io.Threaded.netLookup
  Io.async future
  pthread

  DNS lookup 只是下一個碰到損壞 block 的地方。DNS 程式碼不是已證實的破壞來源。

  另一個透過 FX_HOLD_ON_TRAP 保留下來的程序 PID 65259，有三個執行緒先後碰到相同 allocator invariant：

   執行緒          當時正在執行                被判定損壞的 block
  ━━━━━━━━━━━━━━  ━━━━━━━━━━━━━━━━━━━━━━━━━━  ━━━━━━━━━━━━━━━━━━━━
   UI              terminal repaint                   0x76b02c1c0
  ──────────────  ──────────────────────────  ────────────────────
   Parent agent    subagent tool management           0x76b02f1f0
  ──────────────  ──────────────────────────  ────────────────────
   Child agent     onStreamToolStart                  0x76b02ed20

  三個位址位於同一個 16 KiB xzone slab，但不是相鄰的 32-byte block，也無法確認發生順序。

  ## 研究資料（檔案路徑）

  ### 事件總覽

   資料                  路徑
  ━━━━━━━━━━━━━━━━━━━━  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
   事件主記錄            kfx/incidents/2026-09-05-sigtrap/README.md
  ────────────────────  ───────────────────────────────────────────────────────────
   Held process 調查     kfx/incidents/2026-09-05-sigtrap/held-65259/README.md
  ────────────────────  ───────────────────────────────────────────────────────────
   Malloc 證據稽核       kfx/incidents/2026-09-05-sigtrap/malloc-evidence-audit.md
  ────────────────────  ───────────────────────────────────────────────────────────
   Ownership 靜態稽核    kfx/incidents/2026-09-05-sigtrap/ownership-audit.md
  ────────────────────  ───────────────────────────────────────────────────────────
   原始事故設定          kfx/incidents/2026-09-05-sigtrap/settings.json
  ────────────────────  ───────────────────────────────────────────────────────────
   事故時段 usage        kfx/incidents/2026-09-05-sigtrap/usage-window.jsonl

  ### Crash Reports 與 Binary

   資料                                     路徑
  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
   第一次 crash report                      kfx/incidents/2026-09-05-sigtrap/kfx-2026-09-05-081901.ips
  ───────────────────────────────────────  ────────────────────────────────────────────────────────────
   第二次 crash report                      kfx/incidents/2026-09-05-sigtrap/kfx-2026-09-05-095924.ips
  ───────────────────────────────────────  ────────────────────────────────────────────────────────────
   第三次 diagnostic crash                  kfx/incidents/2026-09-05-sigtrap/kfx-2026-09-05-205212.ips
  ───────────────────────────────────────  ────────────────────────────────────────────────────────────
   第一次事故的原始 binary                  kfx/incidents/2026-09-05-sigtrap/kfx-a12e1c6e-4b28d42b.bin
  ───────────────────────────────────────  ────────────────────────────────────────────────────────────
   含 frame pointer 的 diagnostic binary    kfx/incidents/2026-09-05-sigtrap/kfx-diag-41d872cb.bin
  ───────────────────────────────────────  ────────────────────────────────────────────────────────────
   Hold-on-trap binary                      kfx/incidents/2026-09-05-sigtrap/kfx-diag-84f12b2d.bin
  ───────────────────────────────────────  ────────────────────────────────────────────────────────────
   Register dump binary                     kfx/incidents/2026-09-05-sigtrap/kfx-diag-0d5cfddf.bin

  ### Held Process 證據

   資料                          路徑
  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
   所有執行緒 sample             kfx/incidents/2026-09-05-sigtrap/held-65259/sample-original.txt
  ────────────────────────────  ───────────────────────────────────────────────────────────────────────
   初始 LLDB 狀態                kfx/incidents/2026-09-05-sigtrap/held-65259/lldb-initial.txt
  ────────────────────────────  ───────────────────────────────────────────────────────────────────────
   Fault context                 kfx/incidents/2026-09-05-sigtrap/held-65259/lldb-fault.txt
  ────────────────────────────  ───────────────────────────────────────────────────────────────────────
   Trap 指令解析                 kfx/incidents/2026-09-05-sigtrap/held-65259/lldb-trap-instruction.txt
  ────────────────────────────  ───────────────────────────────────────────────────────────────────────
   其他執行緒 registers          kfx/incidents/2026-09-05-sigtrap/held-65259/lldb-other-registers.txt
  ────────────────────────────  ───────────────────────────────────────────────────────────────────────
   其他執行緒 ucontext           kfx/incidents/2026-09-05-sigtrap/held-65259/lldb-other-ucontexts.txt
  ────────────────────────────  ───────────────────────────────────────────────────────────────────────
   Crash annotation              kfx/incidents/2026-09-05-sigtrap/held-65259/lldb-annotation.txt
  ────────────────────────────  ───────────────────────────────────────────────────────────────────────
   Heap pointer 掃描             kfx/incidents/2026-09-05-sigtrap/held-65259/lldb-pointer-scan.txt
  ────────────────────────────  ───────────────────────────────────────────────────────────────────────
   Child block malloc history    kfx/incidents/2026-09-05-sigtrap/held-65259/malloc-history.txt
  ────────────────────────────  ───────────────────────────────────────────────────────────────────────
   其他 block malloc history     kfx/incidents/2026-09-05-sigtrap/held-65259/malloc-history-other.txt
  ────────────────────────────  ───────────────────────────────────────────────────────────────────────
   Full-mode 驗證資料            kfx/incidents/2026-09-05-sigtrap/held-65259/full-mode-history.txt
  ────────────────────────────  ───────────────────────────────────────────────────────────────────────
   原始 16 KiB slab              kfx/incidents/2026-09-05-sigtrap/held-65259/xzone-slab-76b02c000.bin

  ### 原始 Session

   Session              路徑
  ━━━━━━━━━━━━━━━━━━━  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
   第一次事故 parent    kfx/incidents/2026-09-05-sigtrap/sessions/m3uV9UuSv23X
  ───────────────────  ─────────────────────────────────────────────────────────────
   第一次事故 child     kfx/incidents/2026-09-05-sigtrap/sessions/ZiigI8Cc2pQL
  ───────────────────  ─────────────────────────────────────────────────────────────
   第三次事故 parent    kfx/incidents/2026-09-05-sigtrap/sessions-2052/VD28f0Uop27m
  ───────────────────  ─────────────────────────────────────────────────────────────
   第三次事故 child     kfx/incidents/2026-09-05-sigtrap/sessions-2052/AuArpYch32kJ

  ## 重現腳本

  重現工具位於 kfx/repro。

   腳本                            用途
  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
   kfx/repro/make-replay.py        把事故 recovery checkpoint 轉成 fake Codex response
  ──────────────────────────────  ─────────────────────────────────────────────────────
   kfx/repro/fake-codex.ts         本機 fake Codex SSE server
  ──────────────────────────────  ─────────────────────────────────────────────────────
   kfx/repro/run-persist.sh        Headless parent＋persistent child 重播
  ──────────────────────────────  ─────────────────────────────────────────────────────
   kfx/repro/run-persist-tui.sh    在 tmux TUI 中重播
  ──────────────────────────────  ─────────────────────────────────────────────────────
   kfx/repro/run-grep.sh           長時間、多步工具呼叫壓力測試
  ──────────────────────────────  ─────────────────────────────────────────────────────
   kfx/repro/run-flap.sh           模擬網路中斷與 retry
  ──────────────────────────────  ─────────────────────────────────────────────────────
   kfx/repro/memwatch.sh           收集 RSS、footprint 與執行緒數

  ### 建置

  zig build -Doptimize=ReleaseSafe

  ### 事故形狀重播

  PERSIST_ROUNDS=20 \
  GMALLOC=1 \
  PERSIST_PARENT_STEPS=12 \
  sh kfx/repro/run-persist.sh rca-current-gmalloc

  ### 使用原始崩潰 Binary

  FX_BIN="$PWD/kfx/incidents/2026-09-05-sigtrap/kfx-a12e1c6e-4b28d42b.bin" \
  PERSIST_ROUNDS=100 \
  GMALLOC=1 \
  PERSIST_PARENT_STEPS=12 \
  sh kfx/repro/run-persist.sh rca-crashbin-gmalloc

  ### 已執行結果

   Binary                                                            負載    結果
  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━  ━━━━━━━━━━
   目前 ReleaseSafe binary                                    36 requests    正常結束
  ───────────────────────────────  ───────────────────────────────────────  ──────────
   原始 a12e1c6e binary             116 requests、100 輪 child tool batch    正常結束
  ───────────────────────────────  ───────────────────────────────────────  ──────────
   Fork＋libgmalloc headless                           原始 session shape    未重現
  ───────────────────────────────  ───────────────────────────────────────  ──────────
   Upstream＋libgmalloc headless                       原始 session shape    未重現
  ───────────────────────────────  ───────────────────────────────────────  ──────────
   TUI＋libgmalloc                                     原始 session shape    未重現
  ───────────────────────────────  ───────────────────────────────────────  ──────────
   Plain xzone、paced TUI                                            四輪    未重現

  目前沒有 deterministic reproducer。

  ## 已知線索

  ### 已確認的 Root-Cause 類型

  某段程式碼在 free block 進入 allocator free list 後，改寫了該 block 的內容；另一種可能是相鄰配置發生越界寫入，連帶
  破壞 free-list metadata。

  Allocator 直到後續 malloc 取出該 block 時才偵測到問題。因此 crash stack 只代表偵測點，不代表寫壞記憶體的位置。

  ### 與 Fork 變更的時間關係

  事故 binary 包含 Reclaim transient turn memory 變更。現行 restacked commit 是 629b9b16，事故 binary 中的對應 commit
  是 5b51f130。

  這項變更新增數個短生命週期 c_allocator arena：

  - 每次 provider attempt 一個 arena。
  - 每個 sequential tool call 一個 arena。
  - 每個 parallel tool call 一個 arena。
  - Recovery checkpoint 使用獨立 scratch arena。

  事故發生在安裝這項變更後不久。這是重要的時間相關性，但還不是因果證據。

  ### Malloc History 不能直接歸因

  Held process 使用：

  MallocStackLogging=1

  在目前 macOS 上，這是 lite mode，只保留 live allocation backtrace，不保留完整配置與釋放歷史。

  malloc_history 顯示：

  - 0x76b02c1c0 曾由 recovery checkpoint 的 dupeToolCall 配置。
  - 0x76b02ed20 曾由 onStreamToolStart 配置。
  - 0x76b02f1f0 沒有可解碼紀錄。

  這些 ALLOC row 是舊 metadata。它們不是正在觸發 trap 的新 malloc，也不能指出 free 或非法寫入的位置。

  ### 三個 Block 的關係未知

  三個 block 都是 32 bytes，位於同一個 16 KiB slab，但位址間隔分別是 11,104 與 1,232 bytes。

  因此目前無法證明：

  - 三個 block 是同一個越界寫入連續破壞。
  - 第一個 trap 改變 free list 後，引發後續兩個 trap。
  - 三個 block 原本就各自遭到破壞。
  - 哪一個 trap 最先發生。

  ### Provider 與 DNS 生命週期

  靜態檢查結果：

  - runBoundedHttpOperation 會 cancel 並等待 Select tasks。
  - GatewayCancelWatcher 會在 HTTP request/client 銷毀前停止並 join。
  - HostName.connect 會 cancel 並等待 lookup future。
  - Zig Io.Threaded.cancel 會等待 task 結束。

  目前沒有證據顯示 DNS worker 在 provider attempt arena 銷毀後繼續寫入。

  ### Stream Status 生命週期

  StreamChunkContext 預設使用獨立的 std.heap.c_allocator，不是 provider attempt arena。

  ProvisionalToolStatuses.recordTracked 配置的 tool_id、tool_name 與 label 因此不會隨 attempt arena 一起銷毀。這條直
  接逃逸路徑已排除。

  ### 已知但未命中的懸空指標

  Shell 的 ToolExecutionResult.command_result_json 會配置在 call scratch，copy-out 沒有複製該欄位。

  這是實際存在的 ownership hazard，但目前：

  - Shell 不會進入 parallel tool classifier。
  - 唯一 reader 在 call arena 仍存活時執行。
  - 事故 child 的關鍵 batch 是 read_file、grep_files、glob_files。
  - 單純讀取懸空記憶體也無法直接證明誰寫壞 free-list metadata。

  所以它需要另案修正，但不是目前已證實的事故原因。

  ## 猜測的可能原因（後續研究方向）

  ### 1. Tool-Call Arena 發生非同步逃逸

  最值得優先驗證。

  某個 tool 或底層 std.Io 工作可能保留 call allocator 配置的 mutable buffer，在 execute_tool_call 回傳、call arena 銷
  毀後繼續寫入。

  優先檢查：

  read_file
  grep_files
  glob_files
  skill
  subagent message
  parallel_execution
  tool_runtime
  file I/O futures

  現有 Guard Malloc replay 未觸發，表示它可能需要真實 TUI 時序、特定執行緒交錯或真實檔案系統延遲。

  ### 2. Provider Attempt Arena 發生晚到寫入

  靜態程式碼看起來會等待所有 future，但仍不能排除 Zig 0.16 std.Io.Threaded、HTTP 或 resolver 在特殊錯誤路徑留下
  callback。

  後續應針對下列情境做動態驗證：

  DNS 延遲
  connect timeout
  HTTP cancellation
  429 retry
  SSE 中途斷線
  系統 sleep／resume
  credential refresh

  ### 3. UI 或 Lifecycle Sink 保留 Borrowed Slice

  Agent thread 會把 tool lifecycle、文字 chunk 和狀態傳給 UI。大部分 sink 會同步複製內容，但仍需逐一確認所有錯誤與降
  級路徑。

  重點是找出「事件函式回傳後仍保留傳入 slice」的地方，而不是只檢查正常路徑。

  ### 4. 相鄰 Buffer Overflow

  破壞來源未必是 use-after-free。另一個 live allocation 也可能越界寫進 free block。

  可疑類型：

  ArrayList capacity／length 使用錯誤
  手動 memcpy 長度錯誤
  terminal render buffer
  JSON/SSE parser buffer
  C API 長度或 sentinel 錯誤
  固定大小 stack/heap buffer

  Guard Malloc 對部分小型配置只提供 16-byte alignment，工具本身也警告某些 overflow 不一定會被抓到，因此「Guard Malloc
  沒重現」不能排除此項。

  ### 5. Fork 只改變 Heap Layout，問題原本就在 Upstream

  短生命週期 arena 大幅增加配置與釋放頻率，可能只是讓 upstream 原有的 stale pointer 更容易寫到 allocator metadata。

  有限的 upstream replay 沒有重現，但測試次數不足以排除低機率 race。

  ### 6. macOS Xzone 或 MallocStackLogging 問題

  可能性較低。現有訊息明確標成「BUG IN CLIENT OF LIBMALLOC」，而且三個不同應用程式 call site 都碰到同一種 free-list
  損壞，比較符合 client-side memory corruption。

  除非 client-side 路徑全數排除，否則不應優先懷疑 allocator 本身。

  ## 建議的下一次 Capture

  請從乾淨程序啟動，使用 full stack history，不要再用 lite mode：

  env -u MallocStackLogging \
    MallocStackLoggingNoCompact=1 \
    FX_HOLD_ON_TRAP=1 \
    ./zig-out/bin/fx \
    2>>"$HOME/kfx-trap.err"

  第一次 trap 發生後：

  tail -20 "$HOME/kfx-trap.err"
  malloc_history <pid> <saved-x4-address>
  sample <pid> 1 -file "$HOME/kfx-trap-sample.txt"

  判讀原則：

  - 只信任第一次 trap。
  - ALLOC stack 只能指出該生命週期的配置者。
  - FREE stack 可以把範圍縮到 attempt arena、call arena、turn arena 或 upstream owner。
  - 即使取得 FREE stack，仍需 watchpoint、Guard Malloc fault 或其他動態證據才能確認實際 writer
  - 問題執行檔在這個路徑的 bin/ 裡

