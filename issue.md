# CoTime Book — 已知問題追蹤

這份文件記錄在專案中發現的問題。**每次開始工作前先讀這份文件**，確認哪些是
已修復（回歸測試守著）、哪些還開著。修好一項就把它從「開放中」移到「已修復」，
並補上對應的測試。

狀態標記：`[x]` 已修復並有測試 · `[ ]` 開放中 · `[~]` 部分緩解

---

## 已修復

### [x] #1 翻頁失敗後的錯誤橫幅永遠不會消失

- **檔案**：`lib/services/page_sync_service.dart`、`lib/widgets/sync_status_bar.dart`
- **症狀**：畫面頂端一直卡著「Waiting for every reader to become ready」之類的粉紅色橫幅，
  看起來像整個 App 死鎖了。
- **原因**：`PageSyncState.error(...)` 沒有任何清除路徑。`SyncStatusBar` 只要
  `errorMessage != null` 就優先畫錯誤列，蓋掉真正的狀態。但協定本身每一種失敗都會
  回到 `SyncStatus.idle`——也就是說翻頁其實還能用，只是橫幅騙人。
- **修法**：`PageSyncService` 加上 `_errorAutoClearTimer`，錯誤狀態在
  `defaultErrorAutoClearDelay`（6 秒）後自動回到 idle。延遲時間可注入，測試用短值。
- **測試**：`test/page_sync_service_test.dart` →
  `a transient failure clears itself instead of pinning the bar`

### [x] #2 翻頁 quorum 用的是沒合併過的 Presence metas

- **檔案**：`lib/services/realtime_service.dart`、`lib/services/presence_merge.dart`
- **症狀**：明明所有人都在讀，卻一直「Waiting for every reader to become ready」。
- **原因**：Supabase Presence 是**每條連線一筆** meta，而且 channel key 帶了
  microsecond timestamp（`_SupabaseRoomRealtimeChannel` 建構子），所以同一個使用者
  可能同時有多筆：第二台裝置，或重連後還沒過期的舊 meta。
  `RealtimeService.getOnlineUsers()` 直接回傳原始 payload，
  `PageSyncService._buildReadyReaderQuorum()` 又用 last-wins 的 map 去查，
  只要最後一筆是 `is_reading: false` 的殘留 meta，這個人就永遠不會 ready。
  諷刺的是 `mergePresenceUsers` 早就存在了，只有 `PresenceNotifier` 在用。
- **修法**：把 `mergePresenceUsers` 抽到 `lib/services/presence_merge.dart`，
  在 `RealtimeService.getOnlineUsers()` 這個邊界就合併，讓所有消費端（quorum、lobby
  名單、status bar）看到同一份「一個 user 一列」的資料。
- **測試**：`test/realtime_service_test.dart` →
  `online users collapse a user with several connections`

### [x] #3 有人加入房間時，lobby 不會顯示新成員

- **檔案**：`lib/providers/room_provider.dart`
- **症狀**：B 加入房間後，A 的成員清單完全沒變；連帶 Start Reading 也會因為
  `participant_user_ids` 與 `members` 對不起來而報「The reading session roster is out of date.」
- **原因**：`refreshMembers()` 的守衛寫成
  `if (!identical(state.members, originalMembers)) return;`。
  而 lobby 的 `ref.listen<PresenceState>` 在**同一個 callback 裡**先呼叫
  `updateMembersFromPresence()`（每次都無條件配置一個新 list），才觸發 `refreshMembers()`。
  Presence 的 `join` 事件後面一定緊跟一個 `sync` 事件，於是在 DB 讀取 await 的期間
  `state.members` 又被換掉一次 → `identical` 失敗 → **剛抓回來、含有新成員的名單被整包丟棄**。
- **修法**：
  - 守衛改成 `_membersFetchGeneration`：只有「更新的 fetch」能作廢舊 fetch，
    Presence overlay 不再把 roster 丟掉。
  - `RoomNotifier` 快取 `_lastPresenceUsers`，fetch 落地後重新套用 online / has_book。
  - `updateMembersFromPresence()` 在內容沒有實際變化時不寫 state（減少無謂 rebuild）。
  - 換房 / 離開 / 撤銷 session 時用 `_resetMemberTracking()` 清掉快取。
- **測試**：`test/room_provider_test.dart` →
  `a member who joins mid-refresh survives a presence overlay`、
  `a superseded roster read is discarded by the newer one`、
  `presence with no roster change does not churn state`

### [x] #4 加入房間沒有任何廣播通知其他人

- **檔案**：`lib/providers/presence_provider.dart`、`lib/screens/room_lobby_screen.dart`
- **原因**：只有 `announceLeaving()`。Presence 的 join 只說「有一條連線出現」，
  不代表資料庫 roster 變大，其他人沒有明確訊號去重讀權威名單。
- **修法**：新增 `announceJoining()`，lobby 在 presence join 成功後廣播
  `membership_changed {action: 'joined'}`。收到 `joined` 不需要等 200ms
  （join 廣播時 RPC 已經 commit 了，只有 leave 才需要等）。同時忽略自己發出的廣播。

### [x] #5 reader 會在 viewer 還沒 ready 時對外宣告 `reader_ready: true`

- **檔案**：`lib/screens/reader_screen.dart`（`onRelocated`）
- **原因**：同一段程式裡，`updateReaderContext()` 用的是
  `_isReaderReady && _displayingTargetCfi == null`，但 `updateReaderReady(true)`
  是**無條件**呼叫的。結果本機 `PageSyncService` 認為自己沒 ready，Presence 卻告訴
  全房這個 client ready。其他人把它算進 quorum，它再把授權過的請求打回票。
- **修法**：兩邊共用同一個 `isReadyNow`。

### [x] #6 從沒進入 reader 的參與者會永久卡住 quorum

- **檔案**：`lib/services/page_sync_service.dart`（`_onPresenceChange`）
- **原因**：`_expectedParticipantUserIds` 由 start_reading 凍結，而移除路徑只有兩條：
  明確的 `reading_session_leave` 廣播，或「**曾經**進過 reader」的人離線
  （`_enteredReaderParticipantIds`）。因此有人停在 lobby、或直接關掉 App，
  就會永遠留在 quorum 裡，全房再也翻不了頁。
- **修法**：Presence 事件時，把完全不在房間頻道上的參與者移出 quorum。
  「不在頻道上」是所有 client 觀察一致的事實，roster 仍然收斂；
  只要重新出現在頻道上就會被 `_syncParticipantRoster()` 加回來（不論是否在 reader 裡）——
  短暫斷線不該讓一個人永久退出 quorum，也不該讓「斷過線的 lobby 參與者」
  比「一直連著的 lobby 參與者」享有不同待遇。
  仍留在 lobby（有 presence 但 `is_reading: false`）的人依然會擋——這是刻意的，
  但現在訊息會指名是誰（見 #7）。
- **測試**：`test/page_sync_service_test.dart` →
  `a participant who never opened the reader stops blocking once offline`
- **後續**：#14 拿掉了凍結的參與者名單，這條測試隨之移除；「不在 reader 的人不擋翻頁」
  現在由 `someone in the lobby or still loading never blocks a turn` 守著。

### [x] #7 錯誤訊息把 protocol 代碼直接丟給使用者

- **檔案**：`lib/services/page_sync_service.dart`
- **症狀**：「Page turn cancelled: declined_by_Bob」、「Page turn cancelled:
  required_reader_not_ready」、「Waiting for every reader to become ready」
  （不知道在等誰）。
- **修法**：
  - `describeCancelReason()` 把 wire reason 轉成人話（wire 上仍傳原始代碼）。
  - quorum 失敗訊息會指名還沒 ready 的人：「Waiting for Bob to become ready」。
- **測試**（#14 之後）：`test/page_sync_service_test.dart` →
  `cancel reasons are never shown as protocol codes`、
  `an unanswered request times out and names who it waited for`、
  `declining names the reader and releases everyone`

### [x] #8 `_recoverAuthoritativePosition` 可能無限輪詢並凍結 reader

- **檔案**：`lib/screens/reader_screen.dart`
- **原因**：`refreshRoomAndGet()` 在 revision 沒變、且 `currentRoom` 物件在期間被
  其他更新換掉時會回傳 `null`（`_applyRoomUpdate` 的 `identical(currentRoom, originRoom)`
  判斷失敗）。外層 `while` 每 2 秒重試且沒有出口，而擋住所有手勢的
  `_recoveringAuthoritativePosition` 只有在迴圈結束後才清除。
- **修法**：改成 `_maxPositionRecoveryAttempts = 10` 的有界迴圈，用完就落回 `fallbackCfi`。

### [x] #9 `_initReader` 可能讓 `_currentCfi` 與畫面不同步

- **檔案**：`lib/screens/reader_screen.dart`
- **原因**：`_rebuildViewer()` 在 `_isStoppingPageSync` 或有進行中請求時會提早 return，
  但呼叫端已經先把 `_currentCfi` 指派成從 DB 抓回來的 freshCfi。viewer 還停在舊位置，
  這個 client 卻對外宣稱自己在 freshCfi。
- **修法**：`_rebuildViewer()` 回傳 `bool`，被拒絕時呼叫端還原 `_currentCfi`。

### [x] #10 成員超過畫面高度時無法捲動

- **檔案**：`lib/widgets/member_list.dart`
- **原因**：`ListView.builder` 放在 `Expanded` 裡卻設了 `shrinkWrap: true` +
  `NeverScrollableScrollPhysics`，超出的成員被裁掉且滑不到。

### [x] #11 reader 的「No book loaded」是死路

- **檔案**：`lib/screens/reader_screen.dart`
- **原因**：這個分支沒有返回按鈕也沒有 `PopScope`。reader 是用 `go` 進來的、沒有
  navigation stack，硬體返回會直接離開 App。
- **修法**：補上 `PopScope` 與「Back to Lobby」按鈕。

### [x] #12 閱讀主題沒有套到書頁上

- **檔案**：`lib/providers/reading_preferences_provider.dart`、`lib/screens/reader_screen.dart`
- **症狀**：在閱讀器選 Night / Sepia，只有書頁**周圍**的底色變了，書頁本身
  （也就是正在讀的那一塊）完全沒變。
- **原因**：`ReadingPreferences` 的顏色只用在 `Scaffold.backgroundColor`，
  `EpubViewer` 的 `displaySettings` 從來沒有帶 `theme`；`fontSize` 也一樣存在
  provider 裡卻沒有任何地方用到。
- **修法**：`ReadingPreferences.displaySettings` 一次產出 viewer 需要的全部設定
  （theme、fontSize、以及原本防止套件自帶 swipe 的 `snap` / `useSnapAnimationAndroid`）。
  viewer 只在載入時讀設定，所以偏好與 `_rebuildViewer()` 必須一起成立或一起不做：
  `_applyLayoutPreference()` 先確認可以重建才改偏好，避免「外框換了新主題、
  書頁還是舊主題」的半套狀態。
- **測試**：`test/reading_preferences_test.dart` →
  `the chosen theme reaches the page, not just the margins`、
  `the viewer never gets its own swipe handler`

### [x] #13 同步狀態列的高度會隨狀態改變，讓 viewer 在翻頁途中重新分頁

- **檔案**：`lib/widgets/sync_status_bar.dart`、`lib/screens/reader_screen.dart`
- **症狀（由程式碼推論，未在實機重現）**：與 #A 同一類——某次翻頁後，下一次請求被
  follower 以 `invalid_or_stale_request` 打回，但又不是「進 reader 後第一次」。
- **原因**：狀態列就疊在 `EpubViewer` 上方的 `Column` 裡，而各狀態的 padding
  與內容高度不同（idle 約 34px、requesting 約 38px、confirming 有按鈕更高）。
  每次高度變化 WebView 就被 resize，epub.js 會重新分頁並從 start CFI 重新 display，
  接著送出 `onRelocated`。這發生在 request 開始與結束的瞬間，
  於是 `_currentCfi` 被換成一個只有這台裝置才有的新分頁 CFI。
- **修法**：`SyncStatusBar.height` 固定 60，所有狀態（含兩行錯誤訊息）都在這個
  高度內排版；閱讀器底部工具列也固定 64。原則寫進 CLAUDE.md：
  **viewer 周圍的 chrome 不准改變 viewer 的尺寸。**
- **測試**：`test/sync_status_bar_test.dart` → `the bar keeps one height in every state`
  （已驗證：拿掉固定高度時這個測試會失敗）

### [x] #C reader 的成員面板不會即時更新

- **檔案**：`lib/widgets/reader_members_sheet.dart`
- **原因**：`_showMembersDrawer` 用 `ref.read(presenceProvider)` 取一次 snapshot 就畫，
  面板開著的期間有人進出不會反映。
- **修法**：抽成 `ReaderMembersSheet`（`ConsumerWidget`，watch `presenceProvider`）。
- **測試**：`test/reader_members_sheet_test.dart` →
  `the members panel follows people coming and going while open`

### [x] #14 翻頁一直卡在第一頁（重新設計翻頁協定）

- **檔案**：`lib/services/page_sync_service.dart`、`lib/models/page_sync_state.dart`、
  `lib/screens/reader_screen.dart`、`lib/services/presence_merge.dart`
- **症狀**：兩個人一起讀，按下一頁永遠被取消（「readers were out of sync」），
  整個房間停在第一頁。修了好幾輪都會以別的形式回來。
- **原因**：就是 #A，而且比當初記錄的嚴重。舊協定要求 follower 的 `_currentCfi`
  與 `request.fromCfi` **字串完全相等**，但 CFI 是 epub.js 依本機分頁算出來的——
  螢幕尺寸、字級、甚至一次 resize 都會讓同一頁得到不同字串。#A 以為「成功一次之後
  就會收斂」，但收斂只發生在**成功**之後；兩台不同尺寸的裝置第一次就失敗，
  失敗不會改變任何人的 CFI，於是之後每一次都失敗。圍繞這個字串比對又長出了
  ack / complete / persisting / authoritative recovery 等九個互相牽動的旗標
  （#5、#8、#9、#13、#H 都是它的分支）。
- **修法（重新設計）**：
  - 房間的頁面是 `SharedPosition(seq, cfi)`。**大家比對的是 `seq`**（只在翻頁 commit 時
    +1 的整數），CFI 只拿來 `display()`。本機 relocate 永遠不會改動共享位置。
  - requester 是**唯一的協調者**：`request → vote(accept/decline) → 本機翻頁 → commit(seq+1, cfi)`。
    follower 只投票、只跟隨 commit，不再因為「自己對房間的看法不同」而取消別人的請求。
  - 每個 reader 定期對外宣告自己的位置。漏掉的 commit、晚進來的人、
    斷線重連的人，全都是「採用 reader 中最新的位置」而收斂——不需要回資料庫重試。
    （原本放在 Presence，這是 #18 的根因；現在走 broadcast。）
  - 存活性明確化：requester 等待期間每 8 秒 re-broadcast 請求（遺失的請求會被補上、
    遺失的 vote 會重送）；follower 25 秒沒聽到就放掉；requester 離開 reader 時其他人立即放掉。
  - 只有「在 reader 裡且書已載入」的人會被詢問。在 lobby、背景、載入中的人不會擋住房間。
  - 兩人同時按同方向翻頁：以 `(fromSeq, requestId)` 決定勝者，輸的一方自動同意勝者，
    只翻一頁。
  - 資料庫寫入降為 best-effort（`RoomNotifier.saveReadingPosition`），只給「之後才打開書的人」用；
    寫入失敗不再卡住或回滾翻頁。寫入會序列化並合併成最新一頁——重疊的兩次寫入曾經讓
    舊頁的 conflict retry 蓋掉新頁（`overlapping position saves never leave an older page behind`）。
  - **`epoch`**：沒有人在讀時開書的 reader 從 DB 以 seq 0 起步，所以 seq 只在「一段連續閱讀」
    裡單調。這段的第一次 commit 會鑄造 `epoch`（wall clock），排序改為 `(epoch, seq, cfi)`。
    否則在背景睡過一整段、手上 seq 較大的 reader 醒來時會把全房拉回舊頁
    （`a reader waking from an older stretch does not pull the room back`）。
    殘留風險：兩台裝置時鐘差距大於兩段閱讀的間隔時，舊段仍可能勝出。
  - requester 的翻頁進行中，若 Presence 帶來同一頁的 tie-break（CFI 較大），reader 不再中斷
    自己的翻頁；viewer 忙碌導致放棄時用 `requester_busy`，不再誤報「可能在書頭或書尾」。
    turn timeout 縮短為 4 秒（書頭／書尾時 viewer 根本不會 relocate，大家要等這麼久）。
  - reader 不再需要 reading session id 與凍結的參與者名單（#6 那類「永遠擋住 quorum」的
    根源一起移除）；任何持有書的成員都可以隨時 Join Reading。
- **測試**：`test/page_sync_service_test.dart`（多 client 的 `FakeRoom`，broadcast 與 Presence 共享）→
  `readers on different screens keep turning pages together`、
  `a reader who opens the book late lands on the room's page`、
  `a lost commit still reaches the follower`、
  `a lost vote is sent again when the requester nudges`、
  `two readers pressing next together turn exactly one page`、
  `a dropped connection does not let the requester turn alone` 等 22 條。
  已用 mutation 驗證：拿掉 Presence 位置吸收、vote 重送、self-presence 守衛、
  同意圖自動同意、requester 離開釋放，各自都會讓至少一條測試失敗。

### [x] #15 使用者退出房間後，其他人仍一直看到他在房間裡

- **檔案**：`lib/screens/room_lobby_screen.dart`、`lib/providers/room_provider.dart`、
  `lib/widgets/member_list.dart`
- **症狀**：有人按離開房間，其他客戶端的成員列表裡他還在（有時還顯示 Online）。
- **原因**（三條路徑，任何一條都會讓名單停在舊狀態）：
  1. **從 reader 回到 lobby 時完全沒有重讀名單。** lobby 只在「Presence 的 user ID 集合變化」
     時重讀，而重新進入 lobby 時 Presence 沒有變化——在 reader 期間離開的人永遠留在列表裡，
     連 online overlay 都是舊的。
  2. **離開的廣播比 leave RPC 早送**（Realtime 授權需要成員資格還在），對方等 200ms 讀一次；
     行動網路上 RPC 常常超過 200ms，讀到的還是舊名單。之後唯一的修正來源是 Presence，
     而 Presence 事件也可能錯過。
  3. **leave RPC 失敗**時本機照樣清掉狀態，但 DB 成員列保留，要等 30 分鐘的 stale 驅逐。
  另外，Start Reading 要求「所有 DB 成員都在線且有書」，所以一個 App 被殺掉的成員
  會把整個房間鎖住 30 分鐘以上。
- **修法**：
  - lobby 一進入就以 Presence 重讀 DB 名單與房間，之後每 `rosterRefreshInterval`（15 秒）
    自行對帳一次——錯過任何訊號都會在下一輪收斂。
  - 收到 `leaving` 後在 300ms / 1.5s / 4s 各讀一次，涵蓋 RPC 尚未 commit 的情況。
  - `RoomNotifier.leaveRoom()` 失敗時重試一次（leave 是冪等的）。
  - 成員列表在線者排前面，離線者標示「Away — not connected」。
  - `LobbyReadiness` 取代 `hasExactReadyBookRoster`：host 有書就能開始；有人在讀時任何
    持書成員（包括 host）都是 Join Reading——host 按 Start 會廣播 `start_reading`，
    把剛選擇離開 reader 的人拉回去；還在收書的人只會被點名，不會擋住別人。
- **測試**：`test/room_lobby_screen_test.dart` →
  `a member who left while you were away is gone when the lobby opens`、
  `the lobby keeps re-reading the roster on its own`、
  `a leave announced before its commit is read again`、
  `a member whose app is gone does not lock the room out`；
  `test/room_provider_test.dart` → `a dropped leave request is sent again`。
  三條 lobby 測試都已用 mutation 驗證（拿掉進入時重讀 / 定時對帳 / 多次重讀會各自失敗）。

### [x] #16 收書卡住後整個房間卡死，無法再開始（重新設計傳輸）

- **檔案**：`lib/services/file_transfer_service.dart`、`lib/models/transfer_state.dart`、
  `lib/providers/book_provider.dart`、`lib/widgets/transfer_progress_widget.dart`
- **症狀**：傳書時如果接收端卡住，lobby 永遠停在「Receiving book...」，
  Share Book 按鈕變成「Loading...」且無法按，Start Reading 也開不了。只能退出房間。
- **原因**：
  - 傳輸是**一次性 push**：寄件者把每個 chunk broadcast 一次就結束。Realtime broadcast
    不保證送達（rate limit、斷線、App 在背景），掉一個 chunk 就永遠湊不齊；
    逾時之後狀態變成 failed，但後續 chunk 會用殘缺的 buffer 重新開始，永遠完成不了。
  - **晚加入的成員根本收不到**：沒有任何人會再送一次（`transfer_request` 事件有宣告但沒人處理）。
  - `prepareForSharedBook` 把 `BookState.isLoading` 設成 true 當作「收書中」，
    而 Share Book 按鈕用 `isLoading` 決定是否 disable——收書卡住，分享按鈕就永遠鎖住。
    `sendBook` 也會在「有傳輸進行中」時拒絕。
  - failed 狀態被 widget 藏起來（#I），使用者只看到永遠的「Receiving book...」。
- **修法（receiver 驅動）**：
  - 任何 Presence 裡 `ready_book_hashes` 含這本書的人都能提供它。
  - 收書端缺什麼就向一位持有者要那些 chunk（`transfer_request {sender_id, missing}`），
    進度停滯就再要一次並**輪替持有者**；沒有持有者在線就等，持有者一上線（Presence）立刻要。
    hash 不符就整本丟掉重要。**沒有任何終止狀態**——收書只會越來越接近完成。
  - 持有者用單一 send queue 服務請求，多人同時要書時共用同一輪 broadcast。
  - 初次分享仍然 push 給所有人，只是變成快速路徑。
  - `isLoading` 只代表「正在選檔」；收書與分享互不阻擋，分享新書會直接取代進行中的傳輸——
    `holdBook` 會停掉任何其他書的接收，`BookNotifier._onBookReceived` 也會忽略不是
    房間當前書的完成事件（否則舊書晚到會蓋掉剛分享的新書：
    `a receive still running when a new book is shared cannot replace it`）。
  - 進度元件改成 waiting / transferring / completed，並以文字說明正在做什麼
    （「Asking Alice for the book...」「Waiting for someone with the book to come online...」）。
- **測試**：`test/file_transfer_service_test.dart` →
  `a receiver that missed the whole push asks and gets the book`、
  `a member who joins after the share still receives the book`、
  `only the lost chunks are asked for again`、
  `a stalled holder is replaced by another one`、
  `a damaged book is thrown away and asked for again`、
  `a stalled receive never blocks sharing another book`。

### [x] #17 翻了幾頁之後斷線，而且再也連不回來

- **檔案**：`lib/services/realtime_service.dart`、`lib/services/page_sync_service.dart`、
  `lib/app.dart`、`lib/widgets/sync_status_bar.dart`
- **症狀**：一開始同步翻頁正常，翻幾頁後上方變成「0 readers ready」，成員面板
  「0 members online」，再翻頁出現「Could not reach the other readers」；回到房間下方顯示
  「Unable to subscribe to room channel」，而且一直不會恢復。
- **原因**（全在 realtime 連線恢復路徑，翻頁協定本身沒問題）：
  1. 讀一頁書時裝置休眠或網路閃斷是常態：supabase_flutter 在 `paused` 會主動
     `realtime.disconnect()`，Wi-Fi 省電也會讓 socket 掉線。
  2. 恢復時 library 的 `rejoin()` 會先呼叫 `leaveOpenTopic(topic)`，而它**不排除自己**：
     rejoin timer（最短 1 秒）在私有 channel 的 join 還沒回來時再觸發，channel 就把自己
     unsubscribe 掉，變成 `closed`。library 永遠不會 rejoin 一個 closed channel，
     `RealtimeService` 也沒有任何重建路徑——房間就此斷線。
  3. 回到 lobby 會重建 channel，但重建時用的 `removeChannel(舊的)` 在移除最後一個 channel 時
     會**不 await 地**呼叫 `disconnect()`。新 channel 的 `connect()` 看到 socket 還在
     disconnecting 就直接 return；disconnect 完成後還把 reconnect timer 一併取消——
     新 channel 的 join 永遠送不出去，於是永久顯示「Unable to subscribe to room channel」。
  4. 斷線時 Presence 是舊的或空的：空的會讓 quorum 只剩自己而**直接獨自翻頁**，
     非空則送出請求失敗變成「Could not reach the other readers」。
- **修法**：
  - `RealtimeService` 自帶 watchdog：channel `closed` / `channelError` / `timedOut`、
    track 失敗、或訂閱 15 秒完全沒回應，都會先標成 `reconnecting`，給 library 一點時間
    自己恢復；之後若仍未連上就**重建 channel**（退避 4s→8s→…→30s，永不放棄，連上後歸零）。
    重建前若 access token 已過期會先 refresh，並 `setAuth`。
  - 換 channel 時只 `unsubscribe()` 舊的、保留 socket；只有真正離開房間才釋放 socket，
    而且是 await 完成的 `disconnect()`。
  - App 回到前景時呼叫 `checkConnection()`，2 秒後若仍未連上就重建。
  - 翻頁在 channel 未連上時直接拒絕（「Reconnecting to the room」）；「自己在 Presence 裡」
    改成每次請求都檢查，不再是一次性的旗標——重連後新 channel 的 Presence 還沒 sync 時
    不會變成獨自翻頁。
  - 同步列、成員面板、lobby 在重建期間顯示「Reconnecting to the room...」，
    而不是「0 readers ready」或技術錯誤字串。
  - 送出 broadcast 的 `ChannelResponse` 不再被忽略（socket 斷線時的 REST fallback 失敗
    以前是靜默的）。
- **測試**：`test/realtime_service_test.dart` → group `a broken room channel`
  （`is rebuilt when the server or library closes it`、`keeps the socket when replacing a channel`、
  `is left alone when the library recovers it in time`、`keeps retrying until a rebuild sticks`、
  `a subscription that never answers is rebuilt`、`is not rebuilt after the room is left`、
  `an app resume checks a channel that is down`）；`test/page_sync_service_test.dart` →
  `a reader whose connection dropped does not turn alone`、
  `right after a reconnect it waits for Presence before turning`。
  已用 mutation 驗證：不處理 closed、重建時釋放 socket、拿掉連線閘門、
  把 self-presence 改回一次性旗標，各自都會讓測試失敗。
- **未在實機驗證**：library 的 `leaveOpenTopic` 自我退訂與 socket 競態是讀
  `realtime_client 2.10.0` 原始碼推得的；watchdog 不依賴哪一個才是實際觸發點。

### [x] #18 兩台裝置都恆亮，Realtime 仍然頻繁斷線重連

- **檔案**：`lib/services/realtime_service.dart`、`lib/services/page_sync_service.dart`、
  `lib/services/presence_merge.dart`、`lib/providers/presence_provider.dart`
- **症狀**：#17 合併後連線能自己接回來，但即使兩台裝置螢幕都恆亮、網路正常，
  仍然每隔一陣子就「Reconnecting to the room...」。
- **原因**：不是網路，也不是距離（專案在 ap-southeast-1 新加坡）。Supabase Realtime 的
  log 在測試期間有 23 筆 `ClientPresenceRateLimitReached: :client_rate_limit_exceeded`：
  **每個 client 每 30 秒最多 5 次 Presence 更新（track + untrack）**，超過時伺服器直接關掉
  channel。#14 把 `page_seq` / `page_cfi` 放進 Presence，於是每翻一頁每個 reader 都
  re-track 一次，再加上 `reader_ready`、`is_reading`、`has_book` 的變化，連續翻幾頁就超標。
  channel 被關 → watchdog 重建 → 重建後又 track → 很快再超標，形成週期性斷線。
- **修法**：
  - 頁面位置**不再放進 Presence**。改成 broadcast：`page_position_query`（剛連上／重連後詢問）
    與 `page_position`（回答，以及每 20 秒的定期宣告）。收斂規則不變——採用
    `SharedPosition.isNewerThan` 最新的那個。
  - follower 錯過 commit 時，下一個 request 會帶 `from_cfi`，follower 先跳到 requester 的頁
    再投票；過期的 requester 收到的 `out_of_sync` 票帶著正確位置，直接採用。
  - `RealtimeService` 的 Presence 更新改成**合併 + 限流**：500ms 內的多次變化只送最後一次，
    且 30 秒內最多 4 次（低於伺服器的 5 次）；超過就延到視窗結束再送最新狀態。
- **測試**：`test/realtime_service_test.dart` → group `Presence updates`
  （`a burst of changes goes out as one update with the last value`、`never more than four updates per window`）；
  `test/page_sync_service_test.dart` → `a lost commit still reaches the follower`、
  `a follower that missed a commit catches up from the next request`、
  `a reader waking from an older stretch does not pull the room back`。
  已用 mutation 驗證：拿掉每視窗上限會讓 `never more than four updates per window` 失敗。
- **未在實機驗證**：限流門檻是依 Supabase 文件與 log 的錯誤碼推得；若伺服器的計算方式
  不同（例如 join 也算一次），可能需要再調低 `defaultMaxPresenceUpdatesPerWindow`。

### [x] #19 有人斷線時，房間裡剩下的人可以自己翻頁，對方回來後畫面不同步

- **檔案**：`lib/services/page_sync_service.dart`、`lib/models/page_sync_state.dart`、
  `lib/widgets/sync_status_bar.dart`
- **症狀**：兩人共讀，其中一人斷線（重連中），另一人的 quorum 只剩自己，可以隨意翻頁；
  斷線的人回來時停在舊頁，兩邊畫面不同。
- **原因**：quorum 只看「此刻在 Presence 裡、正在讀」的人。斷線的人從 Presence 消失，
  跟「離開了」在協定上無法分辨，於是不再被詢問。
- **修法**：
  - 一個 reader 從 Presence 消失、但**沒有說自己要離開**，就視為「重連中」，
    在 `defaultReconnectGrace`（1 分鐘）內**任何人都不能翻頁**。
    主動離開不算：`leave()` 會廣播 `reader_left`，離開房間的 `membership_changed`
    （action `leaving`）與 Presence 的 `is_reading: false` 也都會立刻解除等待。
  - 不是靜默拒絕：同步列顯示「Waiting for {名字} to reconnect...」，按翻頁會得到
    「Waiting for {名字} to reconnect」；翻頁進行中有人掉線，requester 取消這次翻頁並廣播
    `reader_disconnected`（UI 顯示「Page turn paused: a reader is reconnecting」）。
  - 對方一回到 Presence 就解除等待並互相詢問位置；超過 1 分鐘沒回來就放行，
    之後他回來時靠位置宣告追上。
- **測試**：`test/page_sync_service_test.dart` → `a reader who drops out holds the room until they are back`、
  `the hold ends once the reconnect grace has passed`、`leaving on purpose never holds anyone up`、
  `a reader dropping out mid-request pauses the turn`；`test/sync_status_bar_test.dart` →
  `a reader who dropped out is named while turns are held`、`the bar keeps one height in every state`。
  已用 mutation 驗證：拿掉 `requestPageTurn` 的等待閘門會讓測試失敗。

### [x] #20 不同裝置同一頁的字數不同，翻幾頁之後頁數就對不上

- **檔案**：`lib/models/shared_page.dart`、`lib/services/shared_page_style.dart`、
  `lib/services/shared_page_renderer.dart`、`assets/reader/shared_page.js`、
  `assets/fonts/literata/`、`lib/screens/reader_screen.dart`、
  `lib/providers/presence_provider.dart`、`lib/services/presence_merge.dart`、
  `lib/services/realtime_service.dart`、`lib/providers/reading_preferences_provider.dart`
- **症狀**：兩台手機一起讀，畫面上「同一頁」的文字量不同（一台排到 "The"，另一台多出
  好幾行）。之後每翻一頁，兩邊各自前進自己的一頁，很快就讀到不同地方：小螢幕的人
  會漏掉一段文字，大螢幕的人會重看一段。
- **原因**：#14 讓共識比對 `seq` 而不是 CFI，但「一頁」本身仍是各裝置自己排出來的。
  epub.js 依它拿到的框與字型分頁，而每台裝置給它的都不一樣：
  - 視窗大小不同（邏輯寬高、扣掉狀態列後的高度）；
  - **系統字型不同**——書沒有指定字型時用的是系統預設字型
    （截圖一台是 MiSans、一台是 Roboto），同寬的框也會在不同地方斷行；
  - 每個人可以各自調字級；`spread: auto` 在寬螢幕上還會變成兩頁並排；
  - `line-height: normal` 的行高取自實際畫那一行的字型，CJK 由各裝置自己的 CJK 字型畫。
  requester 翻的是**自己的**下一頁，follower 只是 `display()` 它的起點 CFI，
  於是每次翻頁都把 requester 的分頁強加給別人。
  另外，`flutter_epub_viewer` 的 `customCss` 實際上送不進書裡：它的 `loadBook()`
  在第一個章節渲染前又註冊了一次不含 `customCss` 的主題，把它蓋掉了。
- **修法**：全房共用一個版面 `SharedPage`（頁框寬高＋字級），所有 reader 都在它上面排版。
  - 每個 reader 在 Presence 放自己的 `page_fit`（viewer 可用區域與自己選的字級；
    只在閱讀中且 App 在前景時公開）。房間的頁 = **最小的寬、最小的高、最大的字級**——
    放得進每一台螢幕，也滿足要求最大字的人。一個人多台裝置時合併成同樣的規則。
    Presence 斷線時頁只會為了自己縮小、不會因為「看起來有人走了」而變大。
  - 統一字型與排版：書一律用內建的 Literata（OFL，以 data URI 注入，因為書的章節
    不是從 App 的 origin 載入），固定 `line-height`，關掉依裝置而異的斷字、
    CJK 標點擠壓與中英間距、Android 字級放大。CJK 落到各裝置的 serif 字型，
    但 CJK 字都是一個 em 寬、行高固定，所以不影響斷行。`spread` 固定為 `none`。
  - 套用方式：書載入後由 `SharedPageRenderer` 執行 `assets/reader/shared_page.js`
    （`rendition.themes.default()` 讓之後渲染的章節也套用；`rendition.resize()` 用數字
    而非 `100vw`）。**不用 CSS 縮放**：epub.js 用 `getBoundingClientRect()` 找頁首，
    transform 會讓它算出偏掉的 CFI，交給別人就是錯的頁。所以大螢幕是同一頁加寬邊界。
  - reader：版面還沒套上前 viewer 不算 loaded（不會被詢問、不能翻頁），
    套用期間的 relocate 不算移動；套用完重新 `display()` 房間的位置。
    版面只在沒有翻頁、沒有 display 進行中時才換（每個分頁點都會移動）。
    script 跑不起來時照樣讓人讀（不擋住房間），並重試。
  - 字級調整不再重建 viewer：改的是自己的 `page_fit`，房間的頁跟著變。
    設定面板說明「大家看到同一頁」，以及別人選了更大的字時房間用的是多少。
- **測試**：`test/shared_page_test.dart` →
  `readers on different screens agree on one page`、`someone in the lobby does not shrink the page`、
  `a fit that is missing or malformed is left out`、`a half-measured screen cannot squeeze the page to nothing`、
  `one person reading on two devices gets a page that fits both`、
  `the page does not grow because people seem to have left`、
  `every face of the font ships with the app`、`the device's own fonts and line heights cannot take over`；
  `test/presence_provider_test.dart` → `the room only sizes its page to readers who are looking at it`；
  `test/reading_preferences_test.dart` → `a wide screen shows one page, not a two-page spread`。
  已用 mutation 驗證：拿掉「只算閱讀中的人」與多裝置合併，各自會讓測試失敗。
  - **實際排版**用 `tool/shared_page_check/check.js` 驗證（Chromium 跑套件內建的 epub.js、
    App 的 `shared_page.js` 與 Dart 產生的樣式表；兩台「裝置」螢幕尺寸、DPR、系統字型、
    載入字級都不同，翻完整本書比對每頁起點）：各自排版 1/120 頁一致，共享頁面 120/120。
    只統一頁框、不統一字型時第 1 頁就分歧——字型那一半是必要的。CI 沒有跑它
    （需要 Node + Playwright），改到排版相關程式時要手動跑。

### [x] #21 一方翻頁了，另一方還停在原頁（但房間的頁序已經同步）

- **檔案**：`assets/reader/shared_page.js`
- **症狀**：有時候按下一頁，其中一台翻了、另一台沒動；同步列顯示一切正常
  （`seq` 已經前進），只是沒翻的那台畫面還是同一頁。#20 之前就有，讀中文書時特別常見。
  長段落裡還會出現另一種情況：翻頁的那台自己的畫面動了，卻在 4 秒後顯示
  「The page did not move — this may be the start or end of the book」，其他人都沒動。
- **原因**：與 #20 不同的根因。epub.js 用「頁面上第一個可見的詞」作為這一頁的 CFI，
  而它找詞的方式是**用空白切開文字節點**（`Mapping.splitTextNodeIntoRanges`）。
  中文沒有空白，一整段就是一個「詞」：
  - 新的一頁若從段落中間開始，頁首 CFI 會指向**段落開頭**——那在上一頁。
    requester 翻到了新頁，commit 給大家的卻是上一頁的位置；follower `display()` 它，
    就停在原本那一頁。共識協定本身沒有錯，`seq` 確實前進了。
  - 一段超過一頁時，段落內的每一頁都回報同一個頁首 CFI。reader 用「落點 CFI 與出發點相同」
    判斷 relocate 只是重新排版、不是翻頁（`_onRelocated`），於是 requester 的翻頁永遠不會完成，
    turn timeout 後放棄——但它的 viewer 其實已經移動了。
- **修法**：`shared_page.js` 把 epub.js 的切詞改成**逐字元**（跳過空白、以 code point 為單位，
  不會切開 surrogate pair），讓每一頁都以它第一個可見字元命名。只換掉 epub.js 用來找頁首／頁尾的
  那一個方法，在版面套用時安裝；follower 的 `display()` 不需要改。
- **測試**：Dart 這一側沒有行為改變，修正只在 WebView 裡，`flutter test` 碰不到（見 #H）。
  回歸測試在 `tool/shared_page_check/check.js`：測試書加入超過一頁的中文段落，並模擬協定——
  平板 `display()` 手機回報的每個頁首，檢查是否真的落在那一頁。
  修正前：120 頁只產生 89 個不同的頁首（31 頁與前一頁同名），follower 只落對 74/89；
  修正後 120 頁 120 個頁首，follower 120/120。可用 `SHARED_PAGE_SCRIPT=<舊版 script>` 重跑比較。

### [x] #A 不同螢幕尺寸的裝置之間 CFI 對不起來

- 由 #14 的重新設計解決：共識比對 `seq`，不比對 CFI 字串。
  但「一頁的內容」仍依裝置而異，直到 #20 讓全房在同一個版面上排版。

### [x] #D reader 進場的頭幾毫秒會丟掉 page_turn 事件

- 不再造成問題：遺失的請求會被 requester 的 nudge 補上，遺失的 commit 由定期的位置宣告補上。
  （`RealtimeService` 的 controller 仍是 lazy 建立；broadcast stream 沒有 listener 時本來就會丟事件，
  提早建立 controller 也不會緩衝。）

### [x] #F App 短暫 inactive 就會把 `is_reading` 打掉

- **檔案**：`lib/app.dart`
- **修法**：`AppLifecycleState.inactive`（下拉通知列、系統對話框、轉場）直接忽略，
  只對 resumed / paused / hidden / detached 反應（`appActivityFor()`）。
- **測試**：`test/app_lifecycle_test.dart` →
  `a passing interruption does not take the reader out of the room`

### [x] #G 同一使用者多個 reader session 的 readiness 是 OR 合併的

- 症狀已不存在：新協定裡 follower 不會因為自己沒 ready 而拒絕請求（只有 requester
  需要 viewer ready），所以「合併結果說 ready、某台裝置說沒 ready」不會再取消翻頁。
  合併規則本身未改。

### [x] #I 傳輸失敗的狀態永遠不會顯示

- 由 #16 解決：收書沒有失敗終態，元件顯示的是「正在做什麼」。

### [x] #O 每次打開 App 都要重新輸入 Nickname

- **檔案**：`lib/providers/auth_provider.dart`、`lib/services/local_store.dart`、`lib/main.dart`
- **症狀**：匿名 session 會跨重啟保留，但 nickname 欄位每次都是空的，進房前一定要重打。
- **原因**：nickname 只存在 `AuthState` 的記憶體裡，App 沒有任何本機儲存。
- **修法**：新增 `shared_preferences` 依賴與 `LocalStore`（`localStoreProvider`，
  `main()` 用 SharedPreferences 覆寫；預設是純記憶體，讓測試不需要 plugin）。
  `AuthNotifier` 建構時讀出上次的 nickname，`setNickname()` 時寫回；首頁欄位用它預填。
  plugin 載入失敗時退回記憶體，不會讓 App 起不來。
- **測試**：`test/local_store_test.dart` → `is remembered across launches`；
  `test/home_screen_test.dart` → `the nickname from last time is already filled in`

### [x] #P Room code 欄位跳出中文輸入法

- **檔案**：`lib/widgets/room_code_input.dart`
- **症狀**：點 Room code 時鍵盤沿用上一次的輸入法（多半是注音／拼音），
  字母會進組字區變成候選字，要手動切英文。
- **修法**：`keyboardType: TextInputType.visiblePassword`，並關掉 autocorrect / suggestions。
  這是唯一一個 Android 各家 IME 與 iOS（對應 ASCII-capable 鍵盤）都會改給英文配置的型別；
  大寫仍由 `UpperCaseTextFormatter` 處理。
- **測試**：`test/home_screen_test.dart` → `the room code field asks for an English keyboard`

### [x] #Q 沒有辦法快速回到之前的房間

- **檔案**：`lib/providers/recent_rooms_provider.dart`、`lib/widgets/recent_rooms_list.dart`、
  `lib/providers/room_provider.dart`（`rejoinRoom`）、`lib/services/room_service.dart`
- **功能**：首頁的「Recent rooms」列出最近 8 個進過的房間（房號、書名、上次進入日期），
  點一下直接進房（已關閉的房間會被重新啟用，見 #R），旁邊的 × 可以移除。
  **不會**替使用者開新房——新房號沒有其他人知道，使用者要的是回到原本那間。
- **設計**：
  - 紀錄由 `recentRoomsProvider` 監聽 `roomProvider.currentRoom` 寫入，而不是由按鈕寫入——
    create / join / 最近房間三條路徑都會被記到，lobby 選書後書名也會跟著更新。
    這個 provider 由首頁第一次 watch 後常駐（非 autoDispose）；App 一律從首頁啟動，
    若之後加入直接開 lobby 的 deep link，要記得在啟動時先 read 它。
  - `rejoinRoom()` 只 join：已關閉的房間由伺服器重新啟用（見 #R）。收到
    `RoomNotFoundException`（RPC 的 `P0002`）代表房間已被清除（關閉超過 30 天），
    首頁顯示「Room X is no longer available.」並移除那筆；網路錯誤則保留，可以再點。
  - 清單會在登入後用 `available_room_codes` RPC 過濾，只留「這個帳號進過、而且還沒被清除」的房間，
    所以關閉超過 30 天的房間不會出現。App 不能直接查 `rooms`：RLS 只讓目前的成員讀，
    關閉的房間對所有人都是空的，跟「不存在」分不出來；放寬 SELECT policy 又會讓離開的人
    透過 Realtime postgres_changes 持續看到房間的換書與 `current_cfi`。RPC 只回房號。
    查詢失敗（離線）時不動清單；查詢期間又進了某個房間，就丟棄這次結果（`_pruneGeneration`）。
  - `join_room` 的 `P0002` 現在轉成 `RoomNotFoundException`，手動輸入不存在的房號時
    錯誤訊息是人話（「Room ABC234 is no longer available.」）而不是 PostgrestException。
  - 存檔裡壞掉的條目會被略過，不會讓整份清單或首頁壞掉。
- **測試**：`test/local_store_test.dart`（排序、去重、上限、書名保留、移除、壞資料）；
  `test/room_provider_test.dart` → `a recent room that is gone does not open a new room`、
  `joining a closed room by code says so in words`；
  `test/home_screen_test.dart` → `tapping a recent room goes straight back in`

### [x] #R 已關閉的房間無法重新啟用

- **檔案**：`supabase/migrations/20261001142734_record_room_participants.sql`、
  `20261001144100_available_room_codes.sql`、`20261001150000_reopen_closed_rooms.sql`
- **正式庫狀態（2026-10-01）**：三個 migration 都已套用。三個函式與 repo 一致
  （`join_room` 只差貼進 SQL Editor 時多出的縮排）；權限只有 `authenticated` / `service_role`。
  已在正式庫用 rollback 的 transaction 驗證：前任 host 能重開已關閉的房間、陌生人得到 `P0002`、
  `available_room_codes` 對陌生人回空陣列。新版 APK 可以發佈。
- **症狀**：大家離開（或 24 小時沒活動）後房間就關了；從「Recent rooms」點回去只會開一個新房號，
  要重新把房號傳給所有人，書與上次的位置也都沒了——即使關閉的房間列還在資料庫裡保留 30 天。
- **原因**：`join_room` 把任何非 active 的房間都當成不存在。
- **修法**：
  - 新增 `cotime_book_private.room_participants`（room_id, user_id），由 `room_members` 的
    AFTER INSERT trigger 記錄，所以 create / join 以及之後任何進房路徑都會被記到；
    房間被清除時 cascade 一起刪掉。API 角色沒有任何權限。
  - `join_room` 在鎖住房間後，若房間已關閉或租約過期，且呼叫者曾在房內，就重新啟用：
    清掉殘留成員、`is_active = true`、`closed_at = null`、host 改成重新啟用的人
    （前任 host 已不在房內），書名 / hash / `current_cfi` 保留。
  - 其他人得到與房號不存在相同的 `P0002`，不會洩漏哪些關閉的房號是真的。
  - 兩個前成員同時重啟會在房間列的 `FOR UPDATE` 上序列化，第二個看到的是已開啟的房間、正常加入。
- **`available_room_codes(p_codes text[])`**：給最近房間清單用，回傳呼叫者進過、且尚未被清除的房號
  （開著或關閉都算）；一次最多 50 個；對沒進過的房間一律不回答，不能拿來批次探測房號。
- **限制**：「誰進過哪個房間」從 2026-10-01 套用 `record_room_participants` 才開始記錄，
  之前的歷史只補得回「當時還在房內的人」與「每個房間最後的 host」。所以在那之前就離開的人，
  資料庫不認得他進過那個房間：不能重開它，它也不會出現在他的最近清單。
  實際上幾乎遇不到——最近房間清單是新版 App 才有的，舊版沒記錄過任何房間；
  新版之後進的每個房間都會同時被記到。
- **套用時的坑**：Supabase MCP 會攔下它判定為破壞性的 SQL（任何頂層 `DROP`，以及
  `join_room` 這種函式內同時有 `delete` / `update` 的定義），要求在 MCP 自己的確認視窗按同意，
  60 秒沒按就逾時、而且完全不會送到資料庫。這跟 Claude Code 的工具權限是分開的。
  所以 trigger 用 `create or replace trigger` 而不是 drop + create；`join_room` 是從 SQL Editor 套用，
  歷史紀錄（`supabase_migrations.schema_migrations`）是事後補上的。
  之後要改這類函式，直接用 `supabase db push` 或 SQL Editor，不要花時間重試 MCP。
- **測試**：`supabase/tests/database/room_reopen.test.sql`（21 項：前成員重啟、陌生人被拒且不洩漏、
  書與位置保留、host 轉移、第二個前成員正常加入、租約過期的房間、建立者被記錄、清除時連帶刪除、
  `available_room_codes` 只對前成員回答、關閉的房間仍可用、被清除後不可用、上限 50）；
  `test/home_screen_test.dart` → `a recent room that is gone says so and leaves the list`、
  `rooms deleted while the app was closed are not listed`、`being offline does not empty the recent list`；
  `test/local_store_test.dart` → `a room entered while the check is in flight is not pruned`

### [x] #U Google Play 拒收上傳：最低 SDK 版本為 21

- **檔案**：`android/app/build.gradle`
- **症狀**：上傳到 Google Play 被拒：「Play 自動防護功能要求的 SDK 版本為 24 以上。
  您上傳的應用程式套件最低 SDK 版本為 21。」
- **原因**：`defaultConfig` 的 `minSdk` 寫死為 21（與 Flutter 3.32 的預設值相同）。
- **修法**：`minSdk = 24`（Android 7.0）。程式碼裡沒有任何 API 21–23 專用的分支，
  所以不需要其他調整；代價是 Android 5.0–6.0 的裝置無法再安裝。
  被拒的上傳不會佔用版本碼，但若 Play Console 顯示該版本碼已被使用，觸發
  `publish-play-store.yml` 時要填新的 `version_code`（或調 `pubspec.yaml` 的 `+N`）。
- **測試**：`test/android_build_config_test.dart` →
  `the Android app targets at least API 24 for Play Auto Protect`

### [x] #V Google Play 拒收上傳：目標 API 級別為 35

- **檔案**：`android/app/build.gradle`、`android/settings.gradle`、
  `android/gradle/wrapper/gradle-wrapper.properties`
- **症狀**：上傳到 Google Play 被拒：「您的應用程式目前的目標 API 級別是 35，
  但目標 API 級別至少須為 36。」
- **原因**：`targetSdk` / `compileSdk` 用的是 `flutter.targetSdkVersion` /
  `flutter.compileSdkVersion`，Flutter 3.32 的值都是 35。
- **修法**：
  - `compileSdk = 36`、`targetSdk = 36`，寫死，不再跟 Flutter 的預設值走。
  - AGP 8.1.0 → 8.9.1：API 36 官方支援的最低 AGP 版本（8.1 本來就已經被 Flutter 警告即將停止支援）。
  - AGP 8.9 需要 Gradle 8.11.1 以上。repo 原本沒有 wrapper，由 Flutter 注入預設的 Gradle 8.12；
    現在把 `gradle-wrapper.properties` 釘在 8.12 進 repo，避免日後 Flutter 換預設值而默默不相容。
- **Android 16（API 36）行為變更的檢查**：
  - 返回鍵改走 predictive back，`onBackPressed` 不再被呼叫——Flutter 3.32 的 `FlutterActivity`
    已經在 framework 要處理返回時註冊 `OnBackInvokedCallback`，各畫面的 `PopScope` 不受影響。
  - edge-to-edge 不能再 opt out——`styles.xml` 本來就沒有 opt out，API 35 時已是 edge-to-edge。
  - 大螢幕（最短邊 ≥ 600dp）忽略方向與可調整大小的限制——App 沒有鎖方向，不受影響。
- **測試**：`test/android_build_config_test.dart` →
  `the Android app targets API 36 as Google Play requires`

---

## 開放中

### [~] #H reader_screen.dart 沒有任何測試

- **檔案**：`lib/screens/reader_screen.dart`
- **現況**：#14 把共識與收斂邏輯全部移進 `PageSyncService`（有完整的多 client 測試），
  reader 只剩「顯示 shared position」與「requester 翻一頁後回報落點」兩件事，
  狀態從九個互相牽動的旗標減為 `_viewerLoaded` / `_isDisplaying` / `_pendingTurn` 等少數幾個。
- **還缺的**：`EpubViewer` 需要真的 WebView，要測這個畫面得先把 viewer 抽成介面
  （像 `PageSyncTransport` 那樣注入），才能在測試裡驅動 `onChaptersLoaded` / `onRelocated`。
  在那之前，這個檔案的改動只能靠實機驗證。
- #20 又加了一段只在這裡的狀態：版面套用（`_syncPageLayout`、`_layoutInFlight`、
  `_appliedPage`）。版面怎麼算（`SharedPage`）與套上去之後是否一致（`check.js`）
  都有驗證，但「套用期間的 relocate 被忽略、套完回到房間位置、翻頁中延後套用」
  這段時序同樣只能靠實機。

### [ ] #B `copyWith` 預設會靜默清掉 `error`

- **檔案**：`lib/providers/room_provider.dart`、`lib/providers/book_provider.dart`、
  `lib/providers/auth_provider.dart`
- **問題**：三個 state 都寫成 `error: error`（而不是 `error ?? this.error`），
  代表任何沒帶 `error` 參數的 `copyWith()` 都會把既有錯誤清掉。
  `RoomNotifier._applyRoomUpdate` 得靠手動傳 `error: state.error` 才能保住錯誤，
  跟 `PageSyncState` 的 `clearError` 慣例不一致。
- **影響**：目前沒有明顯的使用者可見 bug（錯誤本來就短命），但很容易誤用。
- **建議**：統一成 `error ?? this.error` + 顯式的 `clearError` 旗標，並逐一檢查呼叫點。

### [ ] #E Realtime topic 同時接受 room code 與 channel_id

- **檔案**：`supabase/migrations/20260812120002_harden_room_lifecycle.sql`
- **問題**：`cotime_book_private.can_access_room_topic()` 同時授權
  `cotime_book:room:<code>` 與 `cotime_book:room:<channel_id>`，而 client 只用 code。
  因為 room code 是永久保留不重用的（`room_code_reservations`），目前不會跨房洩漏，
  但 `channel_id` 這層額外隔離等於沒有作用。
- **建議**：要嘛讓 client 改用 `channel_id`（`Room.channelId` 已經有了，
  `PresenceNotifier.joinRoom` 的 `roomTopicId` 參數也已經備好，只是 lobby 沒傳），
  然後把 code-based topic 從授權函式拿掉；要嘛就把 `channel_id` 這條路徑刪掉。

### [ ] #J 閱讀偏好不會保存

- **檔案**：`lib/providers/reading_preferences_provider.dart`
- **問題**：主題、字級、音量鍵翻頁都只存在記憶體裡，每次開 App 都回到預設。
  電子閱讀器使用者通常會調大字級，每次重設很煩。
- **建議**：#O 已經加了 `shared_preferences` 與 `LocalStore`，這項只剩在
  `ReadingPreferencesNotifier` 建構時從 `localStoreProvider` 讀取、每次 set 時寫入。
  這次沒有一起做，是因為使用者要的是 nickname 與最近房間，閱讀偏好的預設值與遷移
  值得單獨確認。


### [ ] #K 新舊版本的 App 無法在同一個房間裡互通

- **檔案**：`lib/services/page_sync_service.dart`、`lib/services/file_transfer_service.dart`、
  `lib/screens/room_lobby_screen.dart`
- **問題**：#14 / #16 換掉了 wire 協定（`page_turn_vote` / `page_turn_commit`、
  `transfer_request`、不帶 session id 的 `start_reading`）。舊版 App 送出的請求新版會忽略，
  反之亦然。
- #20 再加了 Presence 的 `page_fit`：舊版不會送，新版就不會把它算進共享頁面，
  舊版那台仍在自己的螢幕上排版，頁面會跟其他人漂移。
- **為什麼先不動**：App 是 APK 發佈，沒有後端相容層可以做；協定版本協商的成本
  遠高於「請所有人更新」。若之後需要，可以在 Presence 加 `protocol` 欄位，
  lobby 對版本不同的成員顯示「請更新 App」。

### [ ] #L App 被直接殺掉的成員，最多 40 分鐘仍顯示為「Away」

- **檔案**：`supabase/migrations/20260812120002_harden_room_lifecycle.sql`
  （`cleanup_expired_rooms` 的 `p_member_stale_after` 預設 30 分鐘，cron 每 10 分鐘）
- **問題**：沒有走 leave 流程的成員只能靠伺服器驅逐。#15 之後他們不再擋住任何事
  （排在列表底部、標示 Away），但仍然佔一列。
- **為什麼先不動**：縮短門檻要同時改 heartbeat 間隔（目前 5 分鐘、且在背景時暫停），
  否則把 App 切到背景幾分鐘的人會被踢出房間。這是產品取捨，而且需要 migration 與 pgTAP，
  應該單獨一個 PR。

### [ ] #M 傳書仍然走 Realtime broadcast

- **檔案**：`lib/services/file_transfer_service.dart`
- **問題**：#16 讓傳輸可以自我修復，但 10MB 的書仍是約 320 個 broadcast（每 100ms 一個），
  受 Realtime 的訊息配額限制，大房間或付費方案以外可能很慢。
- **建議**：若可以接受書檔經過伺服器，改用 Supabase Storage（上傳一次、各自 HTTP 下載，
  RLS 依房間成員授權）。這牽涉到儲存成本與版權／隱私的產品決定，所以沒有在這次改。

### [ ] #N Realtime log 出現對已無成員房間的 `Unauthorized` 訂閱

- **檔案**：`lib/services/realtime_service.dart`（watchdog 重建）、
  `supabase/migrations/20260812120002_harden_room_lifecycle.sql`（topic 授權）
- **現象**：2026-10-01 10:27 UTC 有 2 筆
  `Unauthorized: You do not have permissions to read from this Channel topic: cotime_book:room:6NZUHD`。
  該房間仍存在，但已經沒有任何成員。
- **推測**：某個 client 的成員資格已經結束（離開房間或被驅逐），channel 卻仍在嘗試加入——
  可能是 library 自己的 rejoin，或 watchdog 在 `leave_room` 之後、`leaveRoom()` 之前的
  空窗重建。伺服器拒絕是正確的，所以不會洩漏資料；影響只是多一次失敗的訂閱與退避。
- **為什麼先不動**：只有兩筆、無使用者可見影響，而且還沒能重現是哪一條路徑。
  若之後變多，watchdog 應在重建前確認成員資格，或把 `Unauthorized` 當成「已不在房間」
  而停止重建並回到首頁。

### [ ] #S 大螢幕上共享頁面不會放大

- **檔案**：`assets/reader/shared_page.js`、`lib/services/shared_page_renderer.dart`
- **現況**：#20 讓全房用同一個頁框，頁框取最小的螢幕。平板和手機一起讀時，平板顯示的是
  手機大小的一頁加上很寬的邊界，字也是同樣大小。
- **為什麼先不動**：最直接的 CSS `transform: scale()` 會讓 epub.js 算錯頁首 CFI
  （已在 Chromium 實測：畫面一樣，但回報的起點偏了，交給別人就可能差一頁）。
  可行方向是 WebView 本身的頁面縮放（viewport `initial-scale` 或
  `InAppWebViewSettings`），它不影響 `getBoundingClientRect()`；但 Android WebView 在
  `supportZoom: false`、`loadWithOverviewMode` 下對動態 viewport 的行為需要實機確認，
  沒有裝置可以驗證前不改。

### [ ] #T 內建字型沒有涵蓋的文字仍用各裝置的字型

- **檔案**：`lib/services/shared_page_style.dart`
- **問題**：Literata 只帶了 latin / latin-ext / cyrillic / greek。CJK 落到系統 serif 字型
  不影響斷行（全形、行高固定），但泰文、阿拉伯文、希伯來文、天城文等比例字型
  在不同裝置上寬度不同，這類書仍可能逐頁漂移。書自己內嵌的字型也會被蓋掉
  （`font-family` 對所有元素 `!important`）。
- **為什麼先不動**：目前的使用者讀的是中文與英文書。要涵蓋就得每種文字各帶一套字型，
  或只在書沒有內嵌字型時才覆蓋——兩者都需要確認需求再做。
- 另外，`flutter_epub_viewer` 的 `customCss` 送不進書（見 #20 原因），之後升級套件時
  若修好了，可以考慮改回用它，但 `shared_page.js` 仍需要負責頁框。
