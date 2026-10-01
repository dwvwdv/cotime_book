# CLAUDE.md

給在這個 repo 工作的 Claude Code 的指引。

## 開工前必讀：issue.md

**每次開始任何工作前，先讀 [`issue.md`](./issue.md)。**

- 它記錄了目前已知的問題，分成「已修復」與「開放中」兩區。
- 使用者回報 bug 時，先對照 `issue.md`：可能已經在開放清單裡（有分析與建議修法），
  也可能是已修復項目的回歸（那就去看對應的測試為什麼沒擋住）。
- 修好一項就把它從「開放中」搬到「已修復」，寫清楚**症狀 / 原因 / 修法 / 測試**，
  並補上回歸測試。
- 過程中發現新問題就加進「開放中」，即使這次不修——寫下檔案位置、根因，
  以及為什麼先不動它。
- `issue.md` 是與程式碼同等的產出。改了行為卻沒更新它，這次工作就沒做完。

## 專案概觀

Flutter + Supabase 的共讀 App。多人同處一個房間，共享同一本 EPUB，
翻頁必須經過**全員共識**——任何一人翻頁前，所有人都要確認。

```
lib/
  screens/     home / room_lobby / reader 三個畫面
  providers/   Riverpod StateNotifier（auth, room, presence, book, page_sync）
  services/    Supabase 與 Realtime 的邊界（realtime, page_sync, room, file_transfer）
  models/      不可變的資料型別與 wire 的 JSON 轉換
  widgets/     無狀態 UI 元件
supabase/
  migrations/  依檔名順序套用；schema 是 cotime_book
  tests/       pgTAP（supabase test db）
```

### 需要先理解的幾件事

1. **Presence 是每條連線一筆，不是每個使用者一筆。**
   channel key 帶了 microsecond timestamp，所以一個使用者可能同時有多筆 meta
   （第二台裝置、重連後尚未過期的舊 meta）。
   `RealtimeService.getOnlineUsers()` 已經用 `mergePresenceUsers` 合併成一列一人——
   **不要繞過它去讀原始 payload**，否則 quorum 與名單會對不起來（見 issue #2）。

2. **翻頁是一套共識協定**，不是單純的廣播。狀態機在
   `lib/services/page_sync_service.dart`：
   `request → vote → (requester 本機翻頁) → commit(seq+1, cfi)`。
   - 大家比對的是 `SharedPosition` 的 `(epoch, seq)`，**永遠不要比對 CFI 字串**——
     CFI 依本機分頁而定，不同螢幕同一頁的字串不同（見 issue #14）。CFI 只用來 `display()`。
     seq 只在一段連續閱讀裡單調，跨段靠 `epoch` 排序；排序只定義在
     `SharedPosition.isNewerThan`，位置宣告的合併也用它，不要另寫一份。
   - requester 是唯一的協調者；follower 只投票與跟隨 commit。
   - 每個 reader 用 broadcast 宣告位置（`page_position_query` / `page_position`，
     另有每 20 秒的定期宣告），任何漏掉的訊息都靠「採用 reader 中最新的位置」收斂。
     **不要把頁面位置放回 Presence**——見第 5 點的 Presence 限流（issue #18）。
     資料庫的 `current_cfi` 只是給之後才打開書的人用的 best-effort 紀錄。
   - reader 從 Presence 消失但沒說要離開（`reader_left`、`membership_changed` leaving、
     `is_reading: false`），就視為重連中：1 分鐘內全房不能翻頁，並在同步列寫出在等誰
     （issue #19）。新增「離開」路徑時要記得送出明確的離開訊號，否則會讓別人白等一分鐘。
   - reader 畫面不決定房間在哪一頁：它只顯示 shared position，以及在自己是 requester
     時翻一頁並回報落點。
   改這個檔案前先讀 `test/page_sync_service_test.dart`——它用多 client 的 `FakeRoom`
   把遺失訊息、同時翻頁、斷線等情況都釘住了。

3. **房間成員的權威來源是資料庫，不是 Presence。**
   Presence 只負責 online / has_book 這層 overlay。
   `RoomNotifier.refreshMembers()` 用 `_membersFetchGeneration` 控制順序——
   不要改回用 list identity 做守衛（見 issue #3）。
   lobby 一進入就重讀名單，之後定時對帳——**不要只靠訊號**（Presence 事件、
   `membership_changed`）更新名單，訊號會遺失（見 issue #15）。

4. **房間成員只能透過 `create_room` / `join_room` / `leave_room` 三個 RPC 變動。**
   不要恢復對 `cotime_book.room_members` 的直接 DELETE 權限；RPC 會在 room 母列上
   序列化並行的離開、過期成員驅逐與 host 轉移。

5. **Realtime 連線會斷，而且 library 不一定會自己接回來。** 裝置在讀一頁時休眠是常態。
   `RealtimeService` 有 watchdog 會重建壞掉的 channel（見 issue #17）。
   換 channel 時不要用 `removeChannel()`（它會在背景斷掉 socket），走 `remove(releaseSocket: false)`；
   任何依賴 Presence 的決策都要先確認 `isConnected`——斷線時的 Presence 是舊的或空的。
   **Presence 更新有每 client 每 30 秒 5 次的上限**（track + untrack），超過時伺服器直接關掉
   channel（`ClientPresenceRateLimitReached`）。`RealtimeService` 會合併並限流 Presence 更新；
   Presence 只放變化不頻繁的狀態，會隨翻頁變化的東西一律走 broadcast（見 issue #18）。

6. **傳書是 receiver 驅動的。** `FileTransferService` 的初次分享只是快速路徑；
   收書端缺什麼就向 Presence 裡持有這本書的人要，停滯就輪替持有者再要。
   收書**沒有失敗終態**，也不能阻擋分享新書（見 issue #16）。

7. **錯誤狀態要能自己收斂。**
   `PageSyncState.error` 會在 `defaultErrorAutoClearDelay` 後自動回到 idle。
   任何新加的錯誤狀態都要有清除路徑——永久橫幅會被使用者讀成「App 壞了」。

8. **UI 是為電子紙（e-ink）設計的。** 很大一部分使用者用的是電子閱讀器，不是手機。
   設計系統叫 Paper，定義在 `lib/config/theme.dart`，共用元件在 `lib/widgets/paper.dart`：
   - 狀態不靠顏色傳達（面板是灰階）——用字重、實心/空心、黑白反轉、文字標籤。
   - 不要動畫：不用 `CircularProgressIndicator`（改成「Loading...」之類的文字）、
     snackbar 用 `showPaperMessage()`、bottom sheet 用 `showPaperSheet()`。
   - 不要半透明與陰影；用 1.5px 的線分隔。
   - **viewer 周圍的 chrome 必須固定高度。** 任何改變 `EpubViewer` 尺寸的東西都會讓
     epub.js 重新分頁、改掉本機 CFI（見 issue #13）。

## 指令

```bash
flutter pub get
flutter analyze --no-fatal-infos
flutter test

# 跑起來（Supabase 憑證用 dart-define 傳）
flutter run \
  --dart-define=SUPABASE_URL=https://your-project.supabase.co \
  --dart-define=SUPABASE_ANON_KEY=your-anon-key

# 資料庫
supabase db reset      # 重放 migrations
supabase test db       # pgTAP
```

CI（`.github/workflows/build-check.yml`）跑的是 Flutter 3.32.4：
先 pgTAP，再 `flutter analyze` + `flutter test`，最後建 arm64 APK。
**送 PR 前 `flutter analyze` 與 `flutter test` 必須是乾淨的。**

## 慣例

- 註解解釋**為什麼**，不解釋做了什麼——尤其是那些用來擋掉 race 的守衛。
  這個 codebase 裡幾乎每一條看似多餘的檢查都對應一個真實的 race，
  移除前先確認它擋的是什麼。
- 送出去給使用者看的字串要是人話。protocol 代碼（`required_reader_not_ready`）
  留在 wire 上，UI 走 `describeCancelReason()`。
- 每一個修掉的 bug 都要有回歸測試。測試斷言使用者看得到的行為，
  不要斷言 wire 上的識別字。
- 非同步工作要用 generation counter 防止過期的結果覆蓋新狀態
  （`_roomSessionGeneration`、`_membersFetchGeneration`、`_lifecycleGeneration`、
  `_receiveGeneration`）。新增非同步路徑時沿用這個模式。
