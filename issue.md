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
  - 每個 reader 把 `page_seq` / `page_cfi` 放進 Presence。漏掉的 commit、晚進來的人、
    斷線重連的人，全都是「採用 reader 中最新的位置」而收斂——不需要回資料庫重試。
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
  `a lost commit still reaches the follower through Presence`、
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

### [x] #A 不同螢幕尺寸的裝置之間 CFI 對不起來

- 由 #14 的重新設計解決：共識比對 `seq`，不比對 CFI 字串。

### [x] #D reader 進場的頭幾毫秒會丟掉 page_turn 事件

- 不再造成問題：遺失的請求會被 requester 的 nudge 補上，遺失的 commit 由 Presence 位置補上。
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
- **建議**：加 `shared_preferences`，在 `ReadingPreferencesNotifier` 建構時讀取、
  每次 set 時寫入。這是新增依賴，所以沒有跟這次的樣式重做一起進來。


### [ ] #K 新舊版本的 App 無法在同一個房間裡互通

- **檔案**：`lib/services/page_sync_service.dart`、`lib/services/file_transfer_service.dart`、
  `lib/screens/room_lobby_screen.dart`
- **問題**：#14 / #16 換掉了 wire 協定（`page_turn_vote` / `page_turn_commit`、
  `transfer_request`、不帶 session id 的 `start_reading`）。舊版 App 送出的請求新版會忽略，
  反之亦然。
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
