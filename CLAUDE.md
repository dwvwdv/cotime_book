# CLAUDE.md

給在這個 repo 工作的 Claude Code 的指引。

## 開工前必讀：GitHub issues

**每次開始任何工作前，先看 repo 的 [GitHub issues](https://github.com/dwvwdv/cotime_book/issues)。**

- 開放中的已知問題都在那裡，每一則寫了檔案位置、根因、建議修法，以及**刻意先不修**的理由。
- 使用者回報 bug 時，先對照開放中的 issue：可能已經有分析與建議修法；
  也可能是已修復項目的回歸（那就去看對應的測試為什麼沒擋住）。
- 修好一項就在 PR 裡寫清楚**症狀 / 原因 / 修法 / 測試**，body 用 `Closes #N` 關掉它，
  並補上回歸測試。
- 過程中發現新問題就開一則 issue，即使這次不修——寫下檔案位置、根因，
  以及為什麼先不動它。
- issue 是與程式碼同等的產出。改了行為卻沒更新對應的 issue，這次工作就沒做完。

### 舊的 `issue #N` 編號

以前問題記在根目錄的 `issue.md`，已在 2026-10-21 移除。程式碼、測試、本文件與 changelog 裡的
`issue #14`、`issue #R` 這類編號（數字或字母）都是**舊 issue.md 的項目，不是 GitHub issue / PR 編號**。
已修復項目的完整紀錄（症狀 / 原因 / 修法 / 測試）用 `git show 0006270:issue.md` 查。
當時仍開著的項目搬到了 GitHub：

| 舊編號 | GitHub | 舊編號 | GitHub | 舊編號 | GitHub |
|--------|--------|--------|--------|--------|--------|
| #H | #29 | #K | #33 | #N | #36 |
| #B | #30 | #L | #34 | #S | #37 |
| #E | #31 | #M | #35 | #T | #38 |
| #J | #32 | #Z | #28 | #X | #39 |
| | | | | #Y | #40 |

之後在程式碼註解裡引用 GitHub issue 時寫成 `GH-31`，和舊編號區分開。

## 專案概觀

**頁間**（英文名 CoTime Book）是 Flutter + Supabase 的共讀 App。多人同處一個房間，共享同一本 EPUB，
翻頁必須經過**全員共識**——任何一人翻頁前，所有人都要確認。

```
lib/
  screens/     home / room_lobby / reader，加上首頁的 TXT 轉檔工具與單機預覽
  providers/   Riverpod StateNotifier（auth, room, presence, book, page_sync, txt_convert）
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
   - **「一頁」的內容也是全房共用的**（issue #20）。每個 reader 都在同一個 `SharedPage`
     （最小的頁框、最大的字級，由 Presence 的 `page_fit` 算出）上、用內建字型與固定行高排版，
     由 `assets/reader/shared_page.js` 在書載入後套用。不要讓書回到用本機視窗或系統字型排版，
     也不要用 CSS transform 縮放頁面——epub.js 會因此算錯頁首 CFI。
     閱讀主題（Paper / Sepia / Night）是各人自己的，而且只有顏色：底色由 Flutter 畫在透明的 WebView
     後面，`ReadingPreferences.themeRules` 以 `!important` 把書裡每個元素的底色清成透明、字色換成主題的
     墨色——書自己常寫死白底黑字（Gutenberg 的 `body.tei.tei-text`），不蓋過去主題就沒效果。
     flutter_epub_viewer 1.2.x 的 `loadBook()` 會丟掉傳進去的 custom CSS，所以書載入後由 `applyTheme()`
     再交一次。主題規則不能碰任何影響排版的屬性：同房各人主題不同，分頁必須相同（`check.js` 用 Night 翻完整本比對）。
     比頁框大的螢幕把整頁放大填滿（GH-37），用的是 WebView 自己的 page scale（viewport meta，
     等同 pinch zoom），它不改變 CSS px 與 `getBoundingClientRect()`；WebView 不吃這個縮放時，
     `shared_page.js` 退回不縮放、置中。viewport tag 一定要寫明 `width`：Android WebView
     開著 `useWideViewport`，有縮放卻沒寫 width 時會換成 980px 的 layout viewport（GH-48）。
     桌面 Chromium 沒有這些 WebView quirk，`check.js` 用 `--blink-settings` 把它們打開來跑。
     epub.js 的 `resize()` 遇到「記錄中已經是這個尺寸」會直接略過，所以 `apply()` 一律強制重排，
     並用 `verify()` 確認容器、layout 與每個 view 的欄高都等於頁框；reader 在畫面停下後也會呼叫
     `verify()`，不一致就重新套用（GH-49）。實機上的排版問題請使用者從閱讀設定的
     「Page Layout Report」按「Send Report」——這類問題只在真的 WebView 上出現過。報告經
     `submit_layout_report` RPC 存進 `cotime_book_private.layout_reports`（App 讀不到，從 dashboard /
     SQL Editor 查）：裝置、書、房內每個 reader 的 page_fit、最近幾次移動與 `diagnose()`，
     同一房間同一時刻的報告用 `room_id` 配對；使用者會拿到報告 ID 可以貼進 issue。
     報告的 key 是查詢用的，不要隨意改名；也不要放書的內文、暱稱或 user id。
   - **字級預設由房主決定**：`rooms.text_size_locked`（預設 true）與 `text_size`，只能經
     `set_room_text_size` RPC（host 限定）改。鎖定時每個 reader 在 page_fit 裡要求的是房間的字級
     （`RoomTextSize.requested`），而 `SharedPage` 的算法不變、仍取最大——所以對鎖定狀態一時意見不一
     的 reader（重讀還在路上、不認得鎖的舊版）仍排出同一頁，只是字級暫時偏大。不要把鎖做成
     「只採用 host 的 page_fit」，那會讓沒跟上的 reader 排出不同的頁。房主改完廣播
     `room_settings_changed`，訊號會掉，所以每個 reader（包括同一個 host 帳號的其他裝置）也每 30 秒
     靜默重讀房間。
     頁首 CFI 以「第一個可見字元」計算（`shared_page.js` 換掉了 epub.js 用空白切詞的方法，
     issue #21）——中文沒有空白，用詞切會讓頁首指到上一頁。而且只算「從這一頁開始的那一行」的字：
     不能斷行的長網址會溢出到下一頁的範圍，拿溢出的字當下一頁的名字，`display()` 會回到上一頁，
     全房卡住（GH-52）；共享排版也讓過長的字串與 `pre` 在欄內換行。書裡元素的 `overflow` 一律 visible：
     裁切溢出的容器在分欄排版裡不能拆頁，calibre 的 GitBook 轉檔把整章包在 `overflow: hidden` 裡，
     整章被擠成一頁、其餘被裁掉、翻一頁就跳章（GH-49）。`check.js` 會確認每章最後一段都有某一頁顯示出來。沒有字的頁同理：空白頁在翻頁時
     直接跳過，只有圖的頁以圖的 element CFI 命名（issue #22）。
     底部列的頁數（`PageCounter`）來自 `shared_page.js` 的 `pageInfo()`：章內第幾頁／共幾頁
     與全書百分比。它用和跳過空白頁同一套「這頁有沒有東西」的判斷，不算空白頁——否則翻頁會
     跳號。每章的計數會快取，`layOut()` 一律清掉快取（字級、頁框、修復都會移動分頁點）——新增
     排版路徑時別繞過它。`check.js` 確認兩台裝置的頁數一致、每章從 1 數到最後一頁，以及換字級後
     的頁數等於直接用新字級開書的頁數。
     **跳頁**是帶目的地的翻頁：點底部列的頁數打開 `JumpPreview`，它用第二個 viewer 排在房間的
     `SharedPage` 上（不是自己的螢幕），所以預覽看到的頁首 CFI 就是房間的頁名；滑桿走全書
     （`cfiAtProgress`，問房間 viewer 已算好的 locations），頁數框是「這一章的第幾頁」，和頁數元件
     同一套編號（`pageStart(n)`）。確認後送出 `direction: jump`＋`target_cfi` 的請求，照一般共識流程，
     requester 的 viewer `display(target)`、以落點 commit seq+1。預覽蓋在 viewer 與底部列上、不取代它們：
     房間的 viewer 不能換尺寸（issue #13），所以 reader 的 Scaffold 也不讓鍵盤縮小 body，
     而且用 `ReaderSafeArea`（`maintainBottomViewPadding`）——鍵盤出現時 `MediaQuery.padding.bottom`
     會歸零，一般的 `SafeArea` 會讓 viewer 反而長高、全房重排。預覽的 viewer
     比頁框矮，頁底幾行被滑桿蓋住，但頁不裁切；`check.js` 驗證這樣的 viewer 頁首仍與房間一致，
     並逐頁確認 `pageStart(章內頁碼)` 就是那一頁。廣告時段不能開預覽（會看到被蓋住的頁）。
     改到 `displaySettings`、`SharedPageStyle` 或 `shared_page.js` 時，先在本機跑
     `node tool/shared_page_check/check.js` 確認兩台不同的裝置仍然逐頁一致（本機約 5 分鐘）。
     CI 的 `shared-page-check.yml` 也會在這些來源變動時跑它；但 `check.js` 把 `displaySettings`
     產生的 `loadBook` 參數寫死在檔案裡，改 `displaySettings` 時要同步改 `check.js`，
     否則 CI 驗的仍是舊設定。
   改這個檔案前先讀 `test/page_sync_service_test.dart`——它用多 client 的 `FakeRoom`
   把遺失訊息、同時翻頁、斷線等情況都釘住了。
   - **協定版本**（GH-33）：Presence 帶 `protocol`（`AppConstants.roomProtocolVersion`）與
     `protocol_min`（`minCompatibleRoomProtocol`，還能一起讀的最舊版本）。雙方的版本都不低於
     對方的 `protocol_min` 才算相容；不相容的成員在 lobby 與 reader 標示「需要更新 App」。
     改了 broadcast 事件名稱或 payload、或改了別人依賴的 Presence 欄位時，同一個 PR 要把
     `roomProtocolVersion` +1；舊版跟不上時，`minCompatibleRoomProtocol` 也要拉到新版本。
     **共享頁面的分頁點改變時也算**（`SharedPageStyle` 的規則、`shared_page.js` 的頁首或空白頁判斷）：
     commit 帶的是本機分頁下的頁名，分頁不同的舊版會顯示到別頁。版本 2 就是為了 GH-49 / GH-52 的分頁改變。
     版本 3 是全房廣告時段（GH-63）：舊版跟得上（自己計數播廣告、廣告時段發起的翻頁被拒），所以 `minCompatibleRoomProtocol` 仍是 2。
     版本 4 是跳頁：舊版收到 `direction: jump` 會丟掉、不回應，但跟得上 commit，所以仍相容；
     房內有讀者的 App 低於 `AppConstants.pageJumpProtocol` 時，requester 直接不發出跳頁請求。
     只新增可被忽略的欄位不用改。版號只能往上加。舊版（v1.0.5 以前）不送這兩個欄位，算成 0，
     與目前的版本相容。只提示、不把對方排除在共識之外。

3. **房間成員的權威來源是資料庫，不是 Presence。**
   Presence 只負責 online / has_book 這層 overlay。
   `RoomNotifier.refreshMembers()` 用 `_membersFetchGeneration` 控制順序——
   不要改回用 list identity 做守衛（見 issue #3）。
   lobby 一進入就重讀名單，之後定時對帳——**不要只靠訊號**（Presence 事件、
   `membership_changed`）更新名單，訊號會遺失（見 issue #15）。

4. **房間成員只能透過 `create_room` / `join_room` / `leave_room` 三個 RPC 變動。**
   不要恢復對 `cotime_book.room_members` 的直接 DELETE 權限；RPC 會在 room 母列上
   序列化並行的離開、過期成員驅逐與 host 轉移。
   已關閉（或租約過期）的房間，曾在房內的人可以用 `join_room` 重新啟用——
   依據是 `cotime_book_private.room_participants`（由 `room_members` 的 insert trigger 記錄）。
   其他人一律得到與「房號不存在」相同的 `P0002`，不要讓錯誤訊息洩漏房間是否存在（見 issue #R）。

5. **Realtime 連線會斷，而且 library 不一定會自己接回來。** 裝置在讀一頁時休眠是常態。
   `RealtimeService` 有 watchdog 會重建壞掉的 channel（見 issue #17）。
   換 channel 時不要用 `removeChannel()`（它會在背景斷掉 socket），走 `remove(releaseSocket: false)`；
   伺服器以 `Unauthorized` 拒絕 join 時不重建（GH-36）：`accessDeniedStream` 通知
   `RoomNotifier` 向資料庫確認成員資格，已不在房內就回首頁，否則照常退避重試。
   離開流程一開始就 `suspendRecovery()`，避免在 `leave_room` 之後重建出會被拒的 channel。
   任何依賴 Presence 的決策都要先確認 `isConnected`——斷線時的 Presence 是舊的或空的。
   **Presence 更新有每 client 每 30 秒 5 次的上限**（track + untrack），超過時伺服器直接關掉
   channel（`ClientPresenceRateLimitReached`）。`RealtimeService` 會合併並限流 Presence 更新；
   Presence 只放變化不頻繁的狀態，會隨翻頁變化的東西一律走 broadcast（見 issue #18）。

6. **傳書是 receiver 驅動的。** `FileTransferService` 的初次分享只是快速路徑；
   收書端缺什麼就向 Presence 裡持有這本書的人要，停滯就輪替持有者再要。
   收書**沒有失敗終態**，也不能阻擋分享新書（見 issue #16）。
   使用者自己的書優先走 WebRTC DataChannel 直傳（GH-60）：`SignalingBookPeerLink` 經 Realtime
   只送一則 offer、一則 answer（候選位址先收齊，不 trickle），書本身裝置對裝置，接不通時經
   Cloudflare 託管的 TURN 中繼。Presence 的 `direct_transfer` 標出能直傳的連線；持有者一次只直接
   試一個、試過的不再試，連不上、`FileTransferService` 的 watchdog 判定停滯、或 hash 不符，就回到
   上面的 broadcast。有直傳時分享者**不再 push** 整本書，舊版 App 照晚加入者的方式來要。
   TURN 帳密由 Edge Function `turn-credentials` 發（Cloudflare 的 key 只在 function 的 secrets），
   沒部署時只用 STUN。Android 的 manifest 必須有 `ACCESS_NETWORK_STATE`：libwebrtc 的 NetworkMonitor 在收集
   候選位址時註冊網路回呼，沒有權限時丟出的 `SecurityException` 沒被接住，原生層會直接 abort 整個 App
   （`android_build_config_test.dart` 擋著）。**不要把書或使用者識別放進 signaling 或 TURN 請求**（不帶 `customIdentifier`），
   也不要為傳書記錄誰傳了什麼——這是產品原則，不是疏漏。直傳的協定測試在
   `test/peer_book_link_test.dart`（記憶體裡的 wire），整合在 `file_transfer_service_test.dart` 的
   `direct transfer` 群組。
   公共圖書館的書例外地先由收書端直接下載、以 hash 驗證，失敗或逾時才回到上面的 P2P 路徑
   （issue #M）。書放在 pCloud 的公開資料夾（`AppConstants.libraryUrl`），不放 Supabase Storage
   ——Storage 的 1GB 額度會卡住整座圖書館。`PublicFolderLibraryService` 解析資料夾頁面裡的
   `directLinkData` JSON 列出檔案；資料夾沒有大小上限，所以列表與下載都要擋掉超過
   `AppConstants.maxFileSize` 的書。圖書館只能讀，書由維護者直接放進資料夾。
   書名（`title`，中文）、原文書名與作者、語言（書本身的語言）、tags、封面來自目錄表
   `cotime_book.library_books`，以相對於資料夾的 `path` 對應；App 直接讀這張表、在裝置上和資料夾的
   檔案清單合併，沒有目錄列的書仍要列得出來。`rooms.current_book_library_path` 也是相對於資料夾的路徑。
   Storage bucket `cotime-book-library`、`library_catalog` view 與 `category` 欄位只留給 1.0.12 以前的 App。
   圖書館的說明按鈕讀的是同一資料夾的 `書籍來源聲明.txt`（`AppConstants.libraryNoticeFile`）。
   瀏覽與搜尋在獨立的 `LibraryBrowser`（lobby 的「Library」按鈕），不要塞回「Share Book」
   （issue #AB）。
   TXT 只是匯入格式，而且**不在房間裡轉**：首頁左下角的「TXT to EPUB」工具
   （`TxtConvertScreen` / `txtConvertProvider`）用 `lib/services/txt_book.dart` 轉成 EPUB，
   讓轉換的人先在 `BookPreviewScreen` 單機讀過、存到裝置，再從房間的「Share Book」分享。
   「Share Book」只收 EPUB——不要把 TXT 加回去，轉壞的書會讓整房等。房間裡永遠只有 EPUB
   （PR #27）。不要讓 reader、傳書或儲存認得 TXT；轉換要保持可重現（沒有時間戳、
   沒有隨機 identifier）。預覽用的是與房間相同的 `SharedPage` 規則（一人房的頁框），
   不要讓它另走一套排版，否則預覽看到的分頁不是房間會看到的。

7. **錯誤狀態要能自己收斂。**
   `PageSyncState.error` 會在 `defaultErrorAutoClearDelay` 後自動回到 idle。
   任何新加的錯誤狀態都要有清除路徑——永久橫幅會被使用者讀成「App 壞了」。

8. **UI 是為電子紙（e-ink）設計的。** 很大一部分使用者用的是電子閱讀器，不是手機。
   設計系統叫 Paper，定義在 `lib/config/theme.dart`，共用元件在 `lib/widgets/paper.dart`：
   - 狀態不靠顏色傳達（面板是灰階）——用字重、實心/空心、黑白反轉、文字標籤。
   - 不要動畫：不用 `CircularProgressIndicator`（改成「Loading...」之類的文字）、
     snackbar 用 `showPaperMessage()`、bottom sheet 用 `showPaperSheet()`。
   - 不要半透明與陰影；用 1.5px 的線分隔。
   - 插頁式廣告（AdMob）是唯一的例外：閱讀時每 `AdConfig.pageTurnsPerAd`（20）頁、
     以及 TXT 轉檔存檔前各播一則。**翻頁廣告是全房的「廣告時段」，不是各裝置自己數**（GH-63）：
     共享位置的 `seq` 是 20 的倍數那一頁（`PageSyncService.isAdBreakPage`）大家同時進入。
     不要改回每台裝置自己計數——起算點、廣告有沒有載好都不同，會變成 A 播了 B 沒播。
     廣告載好的人經 broadcast `ad_break` 佔住房間（每個 nudge 重送、liveness 過期，不放 Presence），
     佔住期間它的 `PageSyncService` 自動以 `ad_break` 拒絕任何翻頁請求——所以播廣告時仍是
     `reader_ready: true`，舊版 App 發起的翻頁也會被擋下。到了廣告頁，每個 reader 都用
     `AdBreakCover` 蓋住新的一頁、不能翻頁，直到全房沒有人在看廣告；廣告沒載好（擋廣告的 DNS）
     的人一樣要等，不能趁別人看廣告先讀下一頁。沒廣告的人會先蓋住 `defaultAdBreakSettle`（2 秒）
     等別人的宣告到達，一個人讀時不等。自己的佔住最長 `defaultAdBreakLimit`，宣告遺失時別人在
     liveness 後放行——任何新的佔住都要有這樣的出口。廣告本身不能阻擋流程：沒載好就不佔住
     （`InterstitialAds.show()` 立刻回 false）。廣告是半透明的 Activity，App 只進 `inactive`，
     不會被當成離開房間（`appActivityFor`）。翻頁與存檔各用自己的 ad unit
     （`AdConfig.pageTurnUnitId` / `txtSaveUnitId`），和 `AndroidManifest.xml` 的 App ID 屬於同一個
     AdMob App，要一起改。只有 release build 要正式廣告，debug / profile 與 iOS 一律用 Google 的
     測試 ID（`AdConfig.unitFor`）——開發時點到正式廣告會被 AdMob 算成無效流量。
     **聚合（Mediation）**：Liftoff Monetize 以競價參與，由 AdMob 後台的 Mediation Group 決定誰得標；
     App 端只裝 Google 官方的轉接器外掛 `gma_mediation_liftoffmonetize`，`MobileAds.initialize()`
     會一併初始化它，沒有任何 Dart 呼叫。Liftoff 的 App ID / Placement ID 只填在 AdMob 後台，
     不寫進 App；也不要照 Liftoff 後台的說明手動加 Vungle SDK 或在 Gradle 寫
     `com.google.ads.mediation:vungle`（會與外掛帶進的版本衝突）。外掛版本綁死 `google_mobile_ads`
     的主版號，兩者要一起升。外掛的 Kotlin 2 程式碼需要 Kotlin Gradle plugin 2.1 以上
     （`android/settings.gradle`）。外掛的 Dart API（`setGDPRStatus` 等）不呼叫：之後導入 UMP，
     Liftoff 會讀 IAB TCF 字串。
   - **viewer 周圍的 chrome 必須固定高度。** 任何改變 `EpubViewer` 尺寸的東西都會讓
     epub.js 重新分頁、改掉本機 CFI（見 issue #13）；
     而 viewer 的可用區域就是自己的 `page_fit`，它一變，全房都要重新排版（issue #20）。

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

正式庫的 migration 版本號要跟 `supabase/migrations/` 的檔名一致。用 Supabase MCP 套用時，
頂層 `DROP` 與含 `delete` / `update` 的函式定義會被 MCP 自己的確認攔下、逾時且不執行
（與 Claude Code 權限無關，見 issue #R）——這類 migration 改用 `supabase db push` 或 SQL Editor。

CI（`.github/workflows/build-check.yml`）跑的是 Flutter 3.32.4：
pgTAP 與 `flutter analyze` + `flutter test` + arm64 APK 是兩個平行的 job。
動到排版相關來源（`assets/reader/**`、內建字型、`lib/services/shared_page*.dart`、
`txt_book.dart` / `gb18030.dart`、`tool/shared_page_check/**`、pubspec）時，另有 `shared-page-check.yml` 在 Chromium 裡跑
`tool/shared_page_check`（GH-39）。
**送 PR 前 `flutter analyze` 與 `flutter test` 必須是乾淨的。**
Claude Code 雲端 session 由 `.claude/hooks/session-start.sh` 裝好同版本的 Flutter——
升級 Flutter 時四份 workflow 與這支 hook 要一起改。改 workflow 前先讀
[`build-and-deploy.md`](.claude/skills/build-and-deploy.md) 的「CI 設計筆記」：
paths 過濾、concurrency、Telegram 通知的逾時與備援，每一條都對應踩過的坑。

上架 Google Play 走手動觸發的 `.github/workflows/publish-play-store.yml`（套件名
`com.lazyrhythm.cotime_book`，所需 secrets 與輸入見 README）。每次上傳都要新的版本碼——
記得先調 `pubspec.yaml` 的 `+N`，或在觸發時填 `version_code`。

## Skills 索引

操作流程放在 `.claude/skills/`：

| Skill | 說明 |
|-------|------|
| [version-update.md](.claude/skills/version-update.md) | 版本號何時、怎麼 bump |
| [changelog.md](.claude/skills/changelog.md) | 版本歷史（每次改動都要確認是否要記） |
| [build-and-deploy.md](.claude/skills/build-and-deploy.md) | 環境、構建、上架、CI 一覽與設計筆記 |

Codex 的 code review 規範在根目錄的 [`AGENTS.md`](./AGENTS.md)：什麼值得提出、什麼不要提出。
自己 review 時也照同一套門檻。

## 版本管理

- **唯一的版號來源是 `pubspec.yaml`**（`major.minor.patch+build`，例如 `1.0.1+5`）。
  Gradle 與 CI 都從這裡讀；`+build` 就是 Google Play 的 versionCode，必須遞增。
- **每次功能調整或修復都要 bump**：除非特別指定，只加 `patch`，`build` 一律 +1。
  只動文件、`.claude/`、`.github/` 這類不進 APK 的 PR 不 bump。
- **同一個 PR 最多只疊代一次版本號**：PR 首個需要 bump 的 commit 加 1 之後，
  後續的 review 修復、追加調整都沿用同一版號；changelog 也合併在同一條目下。
  禁止單一 PR 內出現 vX → vX+1 → vX+2。
- **每次改動都要確認是否要更新 [`changelog.md`](.claude/skills/changelog.md)**：
  `### vX.X.X+N (YYYY-MM-DD)`，emoji 前綴 ✨ 新功能 / 🐛 修復 / 🎨 UI / ⚡ 優化。
  對應 GitHub issue 時標出編號（`#31`），細節留在 issue 與 PR。

詳細流程 → [version-update.md](.claude/skills/version-update.md)

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
- PR 的 title、body、review 回覆一律用繁體中文；程式碼、命令與 API 名稱保留原文。
