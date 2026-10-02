# 版本歷史

格式：`### vX.X.X+N (YYYY-MM-DD)`，最新的在最上面。每一項用 emoji 前綴標示類型：
✨ 新功能 / 🐛 修復 / 🎨 UI / ⚡ 優化（含依賴升級、CI、內部重構）。

- 寫給**之後要彙整發版說明的人**看：講使用者看得到的變化，再補一句為什麼。
  protocol 代碼與檔名可以出現，但不要整段只剩識別字。
- 對應 `issue.md` 的項目時標出編號（`issue #21`），細節留在 issue.md，不要兩邊各寫一份。
- 同一個 PR 只有一個版本條目（見 `version-update.md`）；review 修復追加在同一條目下。
- 只動文件、`.claude/`、`.github/` 的 PR 不 bump 版號，不必新增條目。

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
