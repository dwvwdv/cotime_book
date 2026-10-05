# 版本歷史

格式：`### vX.X.X+N (YYYY-MM-DD)`，最新的在最上面。每一項用 emoji 前綴標示類型：
✨ 新功能 / 🐛 修復 / 🎨 UI / ⚡ 優化（含依賴升級、CI、內部重構）。

- 寫給**之後要彙整發版說明的人**看：講使用者看得到的變化，再補一句為什麼。
  protocol 代碼與檔名可以出現，但不要整段只剩識別字。
- 對應 `issue.md` 的項目時標出編號（`issue #21`），細節留在 issue.md，不要兩邊各寫一份。
- 同一個 PR 只有一個版本條目（見 `version-update.md`）；review 修復追加在同一條目下。
- 只動文件、`.claude/`、`.github/` 的 PR 不 bump 版號，不必新增條目。

### v1.0.3+7 (2026-10-05)

- ✨ 圖書館獨立成自己的元件：lobby 多一個「Library」按鈕，打開後可以用書名或作者搜尋，並依分類、語言篩選；「Share Book」回到直接選這台裝置上的檔案（issue #AB）。
- ✨ 圖書館有了目錄：維護者在 `cotime_book.library_books` 填書名、作者、語言、分類，中文書名終於能顯示；還沒建目錄的書照樣列出，標題沿用檔名（issue #AA）。正式庫已套用 `20261005120000_library_catalog.sql`，並為現有 5 本書建好目錄。
- ✨ 圖書館的書有封面：目錄的 `cover_path` 指向 bucket 裡 `covers/` 的圖，書單左側顯示縮圖，沒有封面時顯示書本符號（`20261005130000_library_covers.sql`，正式庫已套用）。
- 🎨 lobby 的按鈕改成兩列：「Share Book / Library」並排，「Start Reading」在下方全寬。

### v1.0.2+6 (2026-10-04)

- ✨ 公共圖書館：lobby 的「Share Book」改成先選來源——這台裝置上的檔案，或圖書館裡的書。圖書館就是 Supabase Storage 的 `cotime-book-library` bucket，維護者把開源 EPUB 放進去，檔名就是書名；App 只能列出與下載。
- ⚡ 分享圖書館的書時不再經過 Realtime 逐塊廣播：收書端直接從 Storage 下載（以 hash 驗證），下載失敗或 60 秒內沒完成才改向房內的人要（issue #M 部分緩解）。
- ✨ 單本書的大小上限從 10MB 提高到 40MB。

### v1.0.1+5 (2026-10-02)

版號規則建立後的第一個版本，起點從 1.0.0+4 往上加。App 本身的行為沒有變。

- ⚡ 從無感記帳移入開發規範：版號與 changelog 規則（`version-update.md`、本檔）、構建與 CI 說明（`build-and-deploy.md`）、Codex review 門檻（`AGENTS.md`），以及雲端 session 自動安裝 Flutter 的 hook。
- ⚡ CI：只改 `assets/` 的 PR 現在也會觸發 Build Check（issue #W）；可手動觸發、同一個 PR 連續 push 時取消舊的 run、runner 可用變數設定、單一測試最多 2 分鐘、Telegram 通知加上逾時與下載連結備援；release 對只改文件的 push 不觸發；新增比對 keystore 指紋的 workflow。

### v1.0.0+4 (2026-02-20 ~ 2026-10-02)

版號規則建立前，這段期間的變更都沒有 bump，全部累積在 1.0.0+4 底下。

- ✨ 上架 Google Play：套件名改為 `com.lazyrhythm.cotime_book`，新增手動觸發的 `publish-play-store.yml`。
- 🐛 `minSdk` 提高到 24（Play Auto Protect，issue #U）、`targetSdk` 提高到 36（issue #V）。
- ✨ 全房共用同一個頁框與字級排版（issue #20），頁首 CFI 以第一個可見字元計算（issue #21）。
- ✨ 記住暱稱、房號欄位強制英文鍵盤、最近的房間清單（issue #O / #P / #Q）；曾在房內的人可重新啟用已關閉的房間（issue #R）。
- 🐛 Realtime channel 斷線時由 watchdog 重建（issue #17）、Presence 更新限流（issue #18）、有人重連中時全房暫停翻頁（issue #19）。
- 🎨 UI 改為電子紙（e-ink）設計系統 Paper。

> 更早的歷史見 `git log` 與 `issue.md` 的「已修復」。
