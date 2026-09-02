# fx 多腦 harness 架構實作計畫

狀態：提案。這份文件定義實驗契約與實作方向，不代表現有程式已具備以下行為。

## Context

這項實驗源自本文末尾的原始文章。原文提出一種 multi-brain harness：同一個 agent 同時維持主 session 與背景 session，背景 session 專門處理 loop 事件，判斷事件應延後合併或立即喚醒主 session。主 session 的 user 與 assistant 訊息會同步給背景 session，但工具歷史不會。兩個 session 都要盡量保住 prompt cache，讓主 session 在大量背景工作執行時仍能回應使用者。

本計畫把上述效果當成產品需求，不把原文當成 fx 現況的證明。fx 已有 persistent subagent、session 持久化、子 session 通訊 ledger、parent delivery，以及背景工作通知；這些元件可供重用，但還缺少 event router 角色、main-to-router intent projection、事件仲裁排程與 urgent wake 狀態機。

第一版採用「同一個 fx process 內的獨立 persistent session」。目前 persistent child 由 `src/core/subagent/execution.zig` 的 `Owner` 以獨立 thread 執行，並非獨立 process。因此第一版提供 session state、model request、consumer cursor 與 transcript ownership 的隔離，不宣稱 process、allocator 或故障域完全隔離。若實驗證明同 process 的共享資源仍會拖慢主 session，再評估獨立 process 或 daemon。

目前程式碼提供的基礎與限制如下：

- `src/core/subagent/domain.zig` 定義 `Mode.persistent`、子 agent 狀態、通知政策與通知週期。
- `src/core/subagent/execution.zig` 以 thread 執行 child session，並已建模 pending、interrupted、awaiting approval 與 terminal work。Interrupted work 必須經明確 retry 或 resume 才能重跑。
- `src/core/subagent/communication.zig` 定義 durable delivery、consumer cursor、`Projection`、`DeliveryKind` 與容量上限。現有 ledger 最多保留 256 筆 delivery，滿載時會淘汰舊資料並把受影響 cursor 標成 stale，因此不能直接拿來證明「事件永不遺失」。
- `src/core/subagent/communication_manager.zig` 的 `poll()` 只讀 durable control 與 communication snapshot，可用穩定 delivery ID 產生可重試的 interval delivery，但它不會自行建立 router work 或啟動模型。
- `src/core/subagent/parent_delivery_projector.zig` 只在新 turn 組裝時準備 parent context，request 可能送達 provider 後才確認 acknowledgement。它不會在 parent idle 或 running 時主動喚醒 worker。
- `src/core/agent/runtime/orchestrator.zig` 目前把 ephemeral overlay 放在 durable history 前面。若 overlay 每次改變，provider 通常只能重用 overlay 之前的 prefix cache，不能據此宣稱完整 history cache 受到保護。
- `src/core/session/session_event.zig` 的 durable identity 是 `(log_generation, seq, event_id)`。Process-local worker turn ID 不足以作為跨重啟的 intent identity。
- `src/core/subagent/control_store.zig` 與 `communication_store.zig` 共用 `subagent-control.lock`，可供同一 child 的控制資料與通訊資料序列化寫入。
- `src/core/app/app_worker_runtime.zig`、`src/core/app/app_callbacks.zig` 與 `tests/e2e/tui-interrupt-recovery.test.ts` 已提供 worker event、互動輸入、排隊 prompt 與中斷恢復的控制面。
- `tests/e2e/tui-subagent-manager.test.ts` 已覆蓋 persistent subagent 的 TUI、持久化通訊與恢復行為。

## Scope

### Included

- 為每個主 session 建立一個角色明確、可恢復且唯一的 event-router persistent child。
- 把外部 loop、子 agent 更新與定時事件送入 main-session-owned durable event ledger。
- 讓 event router 以獨立 consumer cursor 讀取事件，並產生 durable `defer` 或 `wake` decision。
- 讓 `defer` 事件在主 session 下一個 turn 以有界 overlay 合併，不直接修改主 transcript。
- 讓 `wake` 事件立即顯示 urgent notice；若主 model 正在執行，模型處理延後到安全邊界，不強制殺掉 provider request 或工具。
- 只同步主 session 已 durable commit 的 user 與 assistant 內容。工具呼叫、工具結果、progress event 與 rendering event 不進入 intent projection。
- 為 main 與 router 定義能保留最大穩定 prefix 的 merge overlay 位置，並直接驗證序列化 request 的 cache boundary。
- 支援重啟、重試、重複投遞、event router 暫時失敗、主 session 暫時不可用與 bounded-capacity backpressure。
- 為 reducer、ledger、ACP 與 TUI 流程建立 deterministic tests，並更新 PGSO corpus 分類。

### Explicitly excluded

- 第一版不建立通用 webhook 平台，只提供 typed event ingress 與 producer authority。外部來源各自接到 ingress。
- 第一版不提供跨 fx process 的 event-router daemon，也不宣稱 router 與 main 有獨立故障域。
- Event router 不取代主 session，不寫入主 transcript，也不核准 permission prompt。
- 第一版 router 不執行工具。它只讀取 typed event 與 intent overlay，再輸出 typed decision。
- 不把完整主 session 歷史複製到 router。Intent projection 只保留 user、assistant 內容與必要的省略範圍。
- 不強制中斷正在執行的工具或 provider request。Urgent UI notice 可立即出現，model admission 必須等待安全邊界。
- 不保證外部系統的不可逆 side effect exactly once。第一版只保證 fx 自己擁有的 durable decision、model admission 與 acknowledgement 可重試且可去重。
- 不修改 alternate screen、transcript rendering 或 terminal ownership 規則。
- 不把 `FORK.md` 或 `WISHLIST.md` 的既有工作目錄修改納入這次實作。

## Architecture decisions and invariants

### Ownership

- `src/core/multi_brain/` 擁有 event、decision、wake、intent projection 與 brain link 的 typed contract、reducer 和 store。Generic subagent 模組只提供 child session、execution 與 communication primitives。
- Main session 擁有 `BrainLink`、event ledger、intent outbox 與 wake request。Router session 擁有自己的 transcript 與一般 child control record。
- `BrainLink` 必須放在 main-session-owned durable sidecar，使用 schema version 與 atomic replacement。建立、關閉與 stale-link 修復必須在同一個 relationship lock 下完成。
- `src/main.zig` 只負責 composition wiring。Wake admission、recovery 與 UI mapping 放在 `src/core/multi_brain/` 和 `src/core/app/`。

### Concurrency model

- Main 與 router 各自擁有 session state，不得共同寫入同一份 mutable transcript。
- Router child 在同一個 fx process 的獨立 thread 執行。任何共享 lock、provider transport 或 callback 不得在等待 router model 時阻塞主 TUI event loop。
- Event ingress 只做 validation 與 durable append，不直接呼叫模型。
- Event commit 後，dispatcher 以 deterministic router work ID 建立或重用 queue item，再呼叫既有 `execution.Owner.start()` 喚醒 router。重啟時 recovery sweep 對未決事件重建同一個 work ID。

### Delivery guarantees

- 「事件不會靜默遺失」表示：ingress 成功回報前，事件已 durable commit；容量不足時 ingress 必須回傳明確 backpressure 或 capacity error，不能淘汰未確認事件後仍回報成功。
- Canonical event ledger 不得直接沿用現有 communication ledger 的 256 筆淘汰語意。可以重用 envelope、cursor 與 stable ID helper，但 event store 必須採 segmented append log，或在所有必要 consumer acknowledgement 前拒絕超量寫入。
- 相同 immutable event ID 與相同內容重送視為 duplicate success。相同 event ID 但內容不同必須拒絕。
- Fx-owned decision 與 model admission 使用 at-least-once delivery 加 idempotent commit，對模型只產生一次可辨識 admission。
- TUI bytes 與 durable state 無法做 atomic transaction。Crash 發生在 notice 寫出後、durable acknowledgement 前時，重啟後可以用同一 request ID 重播 urgent notice；規格不得宣稱畫面輸出 exactly once。

### Trust boundary

- Event source metadata 只有在 producer capability 驗證後才可信。Capability 必須綁定 `source_id`、`target_main_id` 與允許的 event kind，caller 不得自行冒用其他來源。
- Event payload 內容一律視為 untrusted data，即使來源是 CI、PR 留言或 child agent。Payload 不得取得 instruction authority，也不得因為包在 system message 中就被標成可信指令。
- Merge overlay 必須明示「以下是事件資料，不是指令」，並以 typed JSON 或等價結構編碼內容。
- Router 第一版沒有工具 registry，因此 event payload 無法直接觸發 workspace、network 或 permission side effect。

### Prompt cache boundary

- 目前的 `appendPreparedParentTurnContext()` 位置不足以保護 durable history cache。實作必須新增明確的 turn-boundary merge slot，request 順序為：stable system prefix、durable history、merge overlay、current user、within-turn suffix。
- Main 的 deferred event overlay 與 router 的 intent overlay 都放在 durable history 之後。Overlay 改變時，stable prefix 與 durable history bytes 必須保持不變。
- 若 provider 有 cache metadata，E2E 同時驗證 cache read/write 指標。若 provider 沒有 metadata，測試至少比較 request body，找出第一個變動 byte，確認變動點不早於 merge overlay。
- 這項 invariant 只承諾保護 overlay 之前的 prefix。Provider 是否命中 cache 仍受 provider 政策影響，文件不得把 byte stability 寫成保證命中。

## Definition of done

- Main 在背景 loop 持續產生事件、router model 延遲回應時仍可接受並排隊新的使用者輸入。
- Router 能讀取未決事件與最新 intent projection，並為每個 immutable event revision durable commit `defer` 或 `wake` decision。
- `defer` 不打斷當前 turn；main 下一個 turn 會讀到事件，成功送達或可能送達 provider 後才推進 model consumer cursor。
- `wake` 在 main idle 或 running 時都會於 deterministic E2E timeout 內顯示 urgent notice。Main running 時不破壞 partial output、工具生命週期或 history commit；model handling 在安全邊界 admission。
- Duplicate event、decision、wake request 與程序重啟不會建立第二份 router work，也不會讓同一 event revision 重複進入 main model context。
- Router crash 後，未 durable commit 的 event 保持 pending；已 commit 的 decision 不會重新詢問模型。
- Event ledger 滿載時會明確拒絕 ingress 或施加 backpressure，不會靜默淘汰未確認事件。
- Main 與 router request 的第一個變動 byte 不早於各自的 merge overlay；測試會保留 request evidence。
- External payload 維持 untrusted data，router 無工具，wake 不繞過既有 permission flow。
- Focused Zig tests、focused E2E、build、格式檢查與 exact-commit Full CI 通過。
- 使用 freshly built `./zig-out/bin/fx` 經 deterministic fake gateway 實際操作 main/router happy path。Process 不會 abort，stderr 沒有非預期輸出，main 在背景事件持續產生時仍可互動。

## Data structures first

先固定資料形狀與 owner，再接 runtime callback。

```text
BrainRole = event_router

EventKey {
  source_id: SessionId | LoopId | ExternalSourceId,
  logical_key: bounded text,
}

EventEnvelope {
  event_id: StableEventId,
  key: EventKey,
  source_revision: u64,
  supersedes_event_id: optional StableEventId,
  target_main_id: SessionId,
  work_id: optional WorkId,
  occurred_at_ms: i64,
  payload: EventPayload,
}

EventPayload =
  ci_status |
  human_feedback |
  child_terminal |
  child_milestone |
  timer_tick |
  external_update

ProducerAuthority {
  producer_id: StableProducerId,
  source_id: EventKey.source_id,
  target_main_id: SessionId,
  allowed_kinds: set(EventPayload tag),
}

RouterDecision = defer | wake

DecisionRecord {
  event_id: StableEventId,
  source_revision: u64,
  router_session_id: SessionId,
  router_generation: u64,
  decision: RouterDecision,
  reason: bounded diagnostic text,
  decided_at_ms: i64,
}

WakeRequest {
  request_id: StableRequestId,
  event_id: StableEventId,
  main_session_id: SessionId,
  lifecycle:
    active {
      ui_delivery: pending | presented,
      model_delivery: pending | admitted | possibly_delivered,
    } |
    acknowledged |
    expired |
    superseded,
  created_at_ms: i64,
}

IntentTurnDelta {
  source_session_id: SessionId,
  source_log_generation: SessionLogGeneration,
  source_event_sequence: u64,
  source_event_id: SessionEventId,
  intent_sequence: u64,
  user_message: bounded text,
  assistant_message: bounded text,
  omitted_range: optional SequenceRange,
}

BrainLink {
  schema_version: u64,
  main_session_id: SessionId,
  router_session_id: SessionId,
  event_consumer_id: ConsumerId,
  intent_consumer_id: ConsumerId,
  generation: u64,
  state: active | closing | closed | stale,
}
```

`IntentTurnDelta` 是一個已 commit turn 的單一 projection，不拆成兩次獨立寫入。這可避免 crash 發生在 user delta 與 assistant delta 之間時，只同步半個 turn。

`EventKey` 表示來源中的同一個邏輯對象，例如某個 PR check。每個 revision 都是新的 immutable event：

- 相同 revision 重送時，必須得到相同 `event_id` 與相同內容。
- 新 revision 使用新的 `event_id`，並以 `supersedes_event_id` 指向上一版。
- 比目前最高 revision 更舊的 ingress 視為 stale，不重新仲裁。
- 舊 decision 保留供稽核，但若 event 已被 supersede，尚未送入 main model 的舊 decision 不再 admission。
- 新 revision 可以把舊的 `defer` 升級成 `wake`，因為它是新的 immutable event。

建議事件生命週期如下：

```text
produced
  -> retained
  -> router work scheduled
  -> claimed by router
  -> decision committed
  -> deferred model delivery or urgent wake delivery
  -> acknowledged by each owning consumer
  -> compactable after every required consumer advances
```

Router 讀取事件時不能刪除事件。Decision durable commit 後才能推進 router cursor。Main model request 確定未送出時不能 acknowledgement；request 已送出或可能送出時，沿用 parent delivery 的 delivery-certainty boundary，避免下個 turn 重複注入。

## Alternatives

### A. 在 main worker 內直接分類事件

所有 loop 把事件送給 main worker，由 main model 或同一個 turn 判斷是否處理。

這條路徑最短，但正是原始文章要避免的情況：背景事件會消耗 main 的 model turns，讓使用者輸入與 loop 判斷互相排隊。因此第一版不採用。

### B. 同 process 的 persistent event-router child

Main 與 router 各自擁有 session state、model request、consumer cursor 與 transcript。Router 使用獨立 thread 執行，外部 loop 只寫 durable ledger；decision 與必要 overlay 才回到 main。

第一版採用這個方案。它符合原文的「多個 session 平行運作」，也能重用 fx 現有 persistent child。代價是 main 與 router 仍共用 process、部分 allocator、provider 基礎設施與檔案系統。實作必須用 stall、lock contention 與 queue saturation 測試證明 main 仍可互動，不能只從 session 分離推論可用性。

### C. 獨立 router process 或 daemon

Router process 擁有 event loop 與 model runtime，fx 透過 IPC 連線。這能擴大故障隔離，也可服務多個 fx process，但會新增 process lifecycle、IPC authentication、版本相容與安裝問題。

第一版不採用。若方案 B 無法通過 main availability 測試，或後續需要跨 process fleet supervisor，再另寫 ADR 評估方案 C。

## Applicable skills

實作者開始相關階段前，依工作內容載入：

- `rigor-impl`：遵循資料形狀、階段邊界、獨立驗證與決策紀錄。
- `implement`：執行已核准階段，不自行擴大 scope。
- `review-risk`：檢查 wake、重試、權限、producer authority 與持久化邊界。
- `review-shape`：檢查新模組是否重複既有 subagent、ledger 或 runtime 抽象。
- `code-review`：所有階段完成後，分別檢查 repo standards 與本規格。
- `tw-tech-writing`：更新繁體中文技術文件時維持台灣用語與可驗證敘述。
- `unslop`：檢查 prompt、錯誤訊息、測試名稱與文件文字。

實作者遇到不熟悉的函式時，先讀 `rigor-impl` 的 `references/how.md`，並在該階段工作記錄中寫下 flow、data、boundaries、invariants 與 verification。

## Phases

### Phase 0. 固定實驗契約與可觀察性

**Goal.** 建立 `src/core/multi_brain/` owner，先固定 event、decision、wake、intent 與 link 契約。這一階段不呼叫模型，也不改變使用者行為。

**Changes.**

- 新增 `src/core/multi_brain/domain.zig`，定義上述 domain types、bounded validation、revision rule 與 state transition。
- 在 `src/core/shared/debug_trace.zig` 或 multi-brain trace adapter 增加 bounded fields，至少包含 event ID、revision、router ID、decision、wake state、cursor 與 generation。
- 定義 deterministic test ingress。它只能在 test fixture 或明確 experimental surface 使用，不得變成未授權的 production event injection 後門。

**Verification.**

- 執行 `zig fmt --check src/`。
- 執行 domain focused tests，確認非法 ID、revision rollback、矛盾 supersedes、超長文字與非法 state transition 都會被拒絕。
- 執行 `zig build`。
- 用 fixture 送入一個 event、相同 duplicate、新 revision 與一個 wake request，檢查 trace identity。

### Phase 1. 建立 main-owned event ledger

**Goal.** 所有背景事件先 durable retained，再交給 router。Canonical store 不採現有 communication ledger 的淘汰語意。

**Changes.**

- 新增 `src/core/multi_brain/event_store.zig` 與 pure reducer。Store 由 main session 擁有，具 schema version、segmented retention、consumer cursor 與 atomic replacement 或 append protocol。
- Event ingress 接受 `ProducerAuthority`，在 boundary 驗證 source、target、kind、revision 與 payload size。
- 定義容量策略：未確認事件不可被淘汰；達到 byte 或 segment 上限時回傳 typed backpressure。Compaction 只移除所有必要 consumer 已確認的 prefix。
- Communication 的 stable ID 與 cursor helper 可以重用，但 canonical event 不直接寫入 bounded delivery array。

**Verification.**

- 覆蓋 duplicate event、conflicting duplicate、revision supersede、stale revision、crash before append commit、crash after commit、capacity backpressure 與 cursor acknowledgement。
- 在 temporary session store 重啟後，確認未決事件仍可讀取。
- 建立超過容量的未確認事件，確認 ingress 明確失敗且舊事件仍存在。

### Phase 2. 建立唯一且 durable 的 brain link

**Goal.** 為每個 main session 建立唯一、可恢復、可關閉的 event-router child。

**Changes.**

- 在 multi-brain link store 與 `src/core/subagent/relationship_index.zig` 的適當邊界，加入 role-keyed lookup。不要用 child name 推測 role。
- Bootstrap 在 main relationship lock 下執行 compare-or-install：已有 active router 就回傳原 ID；只有 stale 或 closed link 才能依明確規則修復或重建。
- Router role 與 link generation 存在 durable record。Child control record 保留 generic subagent configuration，不負責判定「每個 main 只能一個 router」。
- Router 固定為 persistent mode、無工具、無 workspace mutation authority，並使用明確 model override 與 notification policy。

**Verification.**

- 兩個 concurrent bootstrap 只建立一個 active router。
- 用 `./zig-out/bin/fx` 建立 router 後重啟，確認 router ID 不變。
- 覆蓋 interrupted、failed、archived、closing 與 stale link；只有明確 resume 或 repair 能重新執行。
- 執行 `cd tests/e2e && bun test tui-subagent-manager.test.ts`。

### Phase 3. 接入 event ingress、scheduler 與 router wakeup

**Goal.** 把 timer、CI、human feedback 與 child update 送入 ledger，並確實排程 router work。

**Changes.**

- 在 `src/core/multi_brain/dispatcher.zig` 接上 event commit、deterministic router work ID 與 `execution.Owner.start()`。
- 重用現有 `WorkNotification`、`poll()`、stable interval ID 與 `next_check_ms`，不要再建立第二個 timer scheduler。
- `src/core/background/background_runtime.zig` 與 app callback 只轉成 typed ingress，不直接呼叫模型。
- Recovery sweep 對「event 已 commit、decision 未 commit」的事件重建同一個 queue item，並喚醒 router。

**Verification.**

- 五個到期 tick 合併成一個 `coalesced_ticks = 5` event。
- Scheduler 重啟後，相同 due time 不會建立第二個 event 或第二個 router work。
- Event commit 後刻意停止程序；重啟時 router 會被喚醒，不需要新 ingress 才開始處理。
- 執行 `cd tests/e2e && bun test notifications.test.ts`，並在 router stall 時輸入新的 main prompt。

### Phase 4. 建立 durable intent outbox

**Goal.** Router 看得到 main 最新意圖，但不重播工具歷史，也不產生半個 turn 的 projection。

**Changes.**

- 在 canonical `history_turn_committed` 邊界產生一筆 `IntentTurnDelta`。Projection 使用 durable session event identity，不使用 process-local worker turn ID。
- Main durable session state 保留 bounded intent outbox 與下一個 intent sequence。Session log compaction 必須把未確認 outbox 帶入 replacement state，不能只保留 history 後丟失 projection identity。
- Projector 只取 user 與 assistant 文字。`ExecutionMemory`、tool call、tool result、progress 與 rendering event 不得進入 delta。
- Router acknowledgement 成功後才能讓 main intent outbox compact。

**Verification.**

- Fake gateway 捕捉 router request，確認 user 與 assistant 依序出現，工具資料完全不出現。
- 在 history event commit 後、intent delivery 前 crash；重啟後同一 `source_event_id` 可重送且只形成一筆 router overlay。
- 在 intent outbox 超過 byte budget 時，確認產生帶 sequence range 的 bounded summary，不靜默刪除未確認範圍。

### Phase 5. 實作 router arbitration

**Goal.** Router child 使用獨立 model 讀取 event 與 intent overlay，再 durable commit `defer` 或 `wake`。

**Changes.**

- `src/core/multi_brain/router_runtime.zig` 組裝 router work。Router 使用空 tool registry，event payload 以 untrusted data envelope 呈現。
- 模型輸出只能是 event ID、source revision、`defer|wake` 與 bounded reason。任意文字先 parse 成 typed candidate，再由 reducer 檢查 active revision 與 router generation。
- Decision commit 與 router cursor advance 必須在同一個 durable mutation，或使用可證明 crash-safe 的 commit protocol。
- 已 superseded event 的 late decision 可保留診斷，但不得進入 main delivery。

**Verification.**

- Fake router 對 milestone 回傳 `defer`，對 CI failure 與 human feedback 回傳 `wake`。
- 無效 decision、錯誤 event ID、舊 revision、超長 reason 與 instruction-like payload 都不會修改 lifecycle state。
- Decision commit 後 crash；重啟不會再次呼叫 router model。
- 大量 interval event 不會塞滿 main worker event queue。

### Phase 6. 接上 deferred merge 與 urgent wake

**Goal.** Deferred event 在 main 下一個 turn 合併；urgent event 立即顯示 notice，並在安全邊界進入 main model。

**Changes.**

- `src/core/multi_brain/main_projection.zig` 準備 deferred context 與 model acknowledgement。只投影 active revision 的 decision。
- 擴充 agent request assembly，新增位於 durable history 後的 merge overlay slot。不要把 multi-brain overlay 塞回現有 history 前方的 generic runtime overlay。
- `src/core/multi_brain/wake_runtime.zig` 擁有 `WakeRequest` reducer 與 admission。`src/core/app/app_worker_runtime.zig` 負責 worker queue 邊界，`app_callbacks.zig` 負責 UI、trace 與 semantic notice mapping。`src/main.zig` 只接線。
- Main idle 時立即 admission；main running 時立即呈現 urgent notice，但 model delivery 保持 pending，直到 current turn finalization 與工具生命週期收束。

**Verification.**

- `defer` 不改變當前畫面；下一個 user turn 的 model request 包含事件。
- `wake` 在 main idle 與 provider response 進行中都於 bounded timeout 內顯示 urgent notice。
- Running wake 不遺失 partial output、tool terminal event 或 history commit；current turn 結束後才建立一個 model admission。
- 在 UI notice 後、durable acknowledgement 前 crash，重啟可用同一 request ID 重播 notice，但不會建立第二個 model admission。
- 執行 `cd tests/e2e && bun test tui-interrupt-recovery.test.ts` 與新增的 multi-brain TUI test。

### Phase 7. 處理 cache、retention 與 restart recovery

**Goal.** 長時間執行時仍維持 bounded context、可恢復 cursor 與可驗證 cache boundary。

**Changes.**

- Event、decision、wake 與 intent store 的 retention 以 acknowledgement 與 byte budget 為準。Summary 必須附 source sequence 與 omitted range。
- Main 與 router 都使用 history 後的 merge overlay。新增 request-capture tests，直接比較第一個變動 byte。
- 建立 main、router、event store、intent outbox 與 wake request 的 crash matrix。

**Verification.**

- 建立超過 context budget 的 event 與 intent 串，確認 overlay 有界且 omitted range 可追蹤。
- 在 event retained、router work scheduled、decision committed、UI presented 與 model possibly delivered checkpoint 分別終止程序，再檢查恢復結果。
- 驗證 fx-owned model admission 不重複；UI replay 使用相同 request ID。
- 若 fake provider 提供 cache metadata，驗證兩個 session 的 cache read boundary；否則驗證序列化 prefix bytes。

### Phase 8. 完成 deterministic E2E、PGSO 分類與文件

**Goal.** 以 built binary 證明原始文章描述的主要產品效果在 fx 第一版成立。

**Changes.**

- 新增 `tests/e2e/multi-brain.test.ts`，覆蓋 main 可互動、defer merge、urgent wake、intent sync、duplicate recovery、capacity backpressure 與 stderr clean。若 ACP 與 TUI 證據無法清楚放在同一檔，再拆成 `multi-brain-acp.test.ts` 與 `tui-multi-brain.test.ts`。
- 每個新增 root E2E file 都在 `scripts/pgso/corpus.json` 有唯一分類。第一版建議 `verification-only`，因為主要覆蓋恢復與併發正確性。
- 更新 `README.md` 或 command help，只記錄已實作且可驗證的實驗行為，不把同 process router 寫成 process isolation。

**Verification.**

- 執行 `zig fmt --check src/`、focused Zig tests、`zig build` 與新增 focused Bun tests。
- E2E 必須使用 repo 中 freshly built `./zig-out/bin/fx`，透過 fake gateway 驅動完整 main/router happy path，不得以 `fx --help` 代替。
- 在 router model 被 fixture 刻意延遲時，從 TUI 送出新的 main prompt；接著注入一個 `defer` 與一個 `wake` event，觀察 next-turn merge、urgent notice 與 safe-boundary model admission。
- 確認 process alive、stderr 空白、event/decision/wake identity 可從 trace 對回 durable store。
- 提交後等待 exact commit 的 Full CI。四個 native runner 與所有 E2E shards 都通過後，才執行最終 ship gate。

## Implementation guidance

### 保持單一事件真相來源

Event ingress 只寫 main-owned event ledger。Callback 不得同時更新 transcript、UI queue 與 router state。Router decision 與 main delivery 都是由 durable event 派生的 effect。

### 先做 reducer，再接模型

`EventEnvelope`、`RouterDecision`、`WakeRequest`、`IntentTurnDelta` 與 `BrainLink` 先以 pure reducer 和 temporary store 測試。模型只能產生候選 decision，不能直接改 durable state。

### 把原文的 cache 需求寫成 byte invariant

「Prompt caching is protected」不能只靠架構圖證明。Main 與 router 都要捕捉實際 request body，確認 overlay 之前的 stable prefix 與 durable history 完全相同。Provider metadata 只能補強證據，不能取代 request ordering test。

### 區分立即通知與安全處理

原文的「wakes main session immediately」在第一版拆成兩件事：urgent notice 立即顯示；main model 在安全邊界處理。這項差異必須留在文件與 UI 語意中，不能把延後的 model admission 描述成任意時刻中斷。

### 保持權限與資料信任邊界

Producer authority 只證明事件來源與路由合法，不代表 payload 內容是指令。Router 沒有工具，main 收到的 event overlay 也必須把 payload 標成 untrusted data。需要 human action 的 decision 回到主 session 既有 permission flow。

### 使用小階段與決策紀錄

實作開始後，在 `.audit/multi-brain.tsv` 維護 append-only decision trail。每列記錄 timestamp、phase、decision、why、evidence 與 result，只收架構分岔、schema 變更、驗證 checkpoint、revert 與 blocker。

每一階段完成後，先檢查實際 diff、測試輸出與 session files，再進下一階段。不要用子 agent 摘要取代 artifact inspection。有爭議的 data shape、cache boundary 或 wake semantics，shipping 前執行 `rigor-impl` 的 `references/interrogate.md`，並記錄選擇。

## Verification commands

以下是最終驗證集合。開發期間先跑改動路徑的 focused tests，不預設每次都跑完整 suite。

```bash
zig fmt --check src/
zig build
zig build test

cd tests/e2e
bun install
bun test tui-subagent-manager.test.ts
bun test tui-interrupt-recovery.test.ts
bun test notifications.test.ts
bun test multi-brain.test.ts
```

`multi-brain.test.ts` 必須直接啟動 repo root 的 `./zig-out/bin/fx`，並執行 main/router 互動、event ingress、`defer`、`wake` 與 restart recovery。`./zig-out/bin/fx --help` 只能當啟動 smoke test，不能作為 multi-brain happy path 證據。

Full CI 必須屬於最後變更的 exact commit。這份計畫不把本地測試冒充 Full CI，也不把編譯成功冒充真實互動驗證。

## Reference. Original post

以下保留完整原文，作為這次實驗的需求背景與術語參考。原文描述目標效果，不替 fx 的隔離層級、delivery guarantee 或 cache 行為背書；這些契約以前文為準。

```text
sharing a recent breakthrough in harness architecture i achieved with
@pidotdev

this is not a common problem but it happens when your agent starts to handle loops that would fire events from the background. e.g. the agent is babysitting a PR, and it checks every 5 minutes whether there are CI errors or human feedback

when your agent is juggling a lot of such loops, eventually you will see it becoming too busy to even talk to you. it’s just handling these events all the time and making judgment calls for whether they need any actions or not

this problem is particularly prevalent in firstmate because it’s playing an orchestrator role and needs to respond to various kinds of updates from the whole fleet

i experimented multiple approaches and eventually created this multi-brain harness architecture where:

- a single agent can have multiple sessions running in parallel

- the main session is the one you talk to

- then there’s also a session running in the background (can use a cheaper model too) that specifically handles events from loops

- the background session will decide whether an event needs to interrupt the main session or not

- most events don’t need to, but they don’t get silently dropped. they get “merged” into the main session like git commits merge between branches, and they get seen when main session takes the next turn, so context is not lost

- events that do need human attention wakes main session immediately

- user and agent messages (not tool calls) in main session get merged into the background session, so when the background session makes decisions, it has the context and intent

- both sessions’ prompt caching is protected during these merged so requests keep being cheap

result is quite incredible - the main agent remains available for user interaction while a ton of loops can be running and doing work

@pidotdev
 is pretty much the only mainstream harness where this can be achieved seamlessly due to its deep customizability. you can build this in your custom harnesses too. sharing here in case anyone building similar systems face this problem!
```
