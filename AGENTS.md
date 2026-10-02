# AGENTS.md

## 專案文件

在進行任何程式碼修改、分析或 Pull Request Review 之前，**必須先閱讀根目錄的 `CLAUDE.md` 與 `issue.md`**。

- `CLAUDE.md` 是本專案主要的開發與架構文件：翻頁共識協定、Presence 與資料庫的權威分工、
  房間成員只能經 RPC 變動、Realtime 斷線與限流、e-ink 的 UI 限制、開發與測試慣例。
- `issue.md` 記錄已修復（有回歸測試守著）與開放中的問題，包含**刻意先不修**的理由。

不要只根據目前 PR diff 推測專案規則。

如果某段程式碼看起來可以「更完整」、「更安全」或「更通用」，但 `CLAUDE.md` 或 `issue.md`
已明確記錄這是刻意接受的 trade-off，**不要把它重新提出為 Review finding**，除非這次 PR
改變了原本成立的前提。

`CLAUDE.md` 負責專案與 domain 規則；本 `AGENTS.md` 主要補充 Codex 的 Review 行為規範。
如果兩者沒有衝突，必須同時遵守。

---

## GitHub Pull Request 語言規範

所有 GitHub Pull Request 的 title、body、comment、review 回覆與 review 結果，
一律使用繁體中文。技術識別字、程式碼、命令與 API 名稱可保留原文。

---

## Code Review 原則

進行 Pull Request Review 時，優先找出「實際值得修、會影響產品」的問題。

不要為了理論完整性，持續追查極低機率、刻意構造、正常使用幾乎不可能出現的邊界情況。

### 什麼問題值得提出

只有至少符合以下一項時，才應提出 finding：

- 正常使用流程或合理可預期的操作可能觸發（包含裝置休眠、斷網重連、App 被切到背景——
  這些在本專案是**常態**，不是邊界情況）
- 可能讓房間裡的人看到不同頁、翻頁永久卡住、或名單與實際成員對不起來
- 可能造成安全或隱私問題（RLS、RPC 權限、錯誤訊息洩漏房間是否存在）
- 可能造成 crash 或核心功能無法使用
- 是本 PR 新增或明顯暴露出的 concurrency、lifecycle、migration 或 compatibility 問題
- 問題雖低機率，但一旦發生會讓房間進入無法自行恢復的狀態

### 什麼問題通常不要提出

- 必須輸入極端長文字或刻意構造巨大輸入才會發生
- 純粹為了撞底層實作限制（訊息大小、整數上限、collection size）
- 需要極端不合理 timing 才可能發生，而且沒有明確產品影響、也會被既有收斂機制
  （定期位置宣告、名單定時對帳）自己修好的理論 race condition
- 必須手動竄改資料庫、修改 App 內部檔案或違反既有 invariant 才能觸發
- 現有行為在正常產品使用範圍內已經正確，只是還可以做更多 defensive hardening
- 主要收益只是架構更漂亮、更加通用、未來可能更容易擴充，而不是修正實際問題
- 與本 PR 無直接關係的既有問題，除非它會直接讓這次修改無法正確運作
- `CLAUDE.md` / `issue.md` 已明確記錄並接受的 trade-off，且本 PR 沒有改變相關前提

### Edge case 處理原則

遇到極端 edge case 時，優先考慮**簡單的產品限制**（限制長度、限制人數、顯示清楚的錯誤），
而不是增加大量實作機制、狀態與 recovery 邏輯。

---

## Finding 提出門檻

提出 finding 前，先確認：

1. 這個問題是本 PR 引入或明顯暴露的
2. 有具體、可描述的實際觸發流程
3. 有明確的使用者影響
4. 問題的嚴重程度值得增加程式碼與長期維護成本
5. 沒有更簡單的產品限制能合理解決
6. `CLAUDE.md` / `issue.md` 沒有已經把這件事列為刻意接受的限制

每個 finding 應說明：

- **實際觸發方式**
- **具體影響**
- **為什麼值得在這個 PR 修**

不要只證明「理論上可能發生」。

---

## Review 優先級

優先檢查：

1. 翻頁共識協定的正確性（比對 `(epoch, seq)` 而不是 CFI、requester 是唯一協調者）
2. 會讓房間卡住、無法自行收斂的狀態（永久錯誤橫幅、永久等待某人）
3. 房間成員與 host 轉移的正確性（只經 RPC、generation counter 擋過期結果）
4. 正常操作可以觸發的 race condition（斷線重連、多裝置、同時翻頁）
5. 核心 workflow regression（建房、加入、傳書、開始閱讀、翻頁）
6. Migration / RLS / RPC 權限 / 舊版 App 相容性
7. Security / privacy
8. 明確且可重現的 UI 行為錯誤（含改變 viewer 尺寸而觸發重新分頁）

低優先級：

- 純架構潔癖
- 理論 extensibility
- 極端輸入
- 微小 defensive hardening
- 幾乎不可能達到的 implementation limit

---

## 產品規模假設

這是一個**幾個人一起讀同一本書的共讀 App**，不是大型即時協作平台。
一個房間通常是個位數的人，Review 應以這個規模為前提。

不要因為底層 library 理論上允許無限輸入，就要求 App 支援刻意構造的極端情境
（上百人的房間、上千頁的翻頁佇列、刻意製造的訊息風暴）。

如果合理的產品限制可以解決，就採用產品限制。

---

## Review Scope

不要把 Review 變成無限延伸的全專案 audit。

當一個 finding 被修正後，應檢查：

- 修正本身是否正確
- 是否造成直接 regression
- 是否破壞本 PR 涉及的既有 invariant

不要因為修正了一個問題，就沿著所有理論依賴一路擴展到與本 PR 幾乎無關的歷史問題。

Review 的目標是：

> 判斷這個 PR 是否值得安全地合併。

不是：

> 證明整個程式在所有理論輸入與所有可能執行順序下都完美。

**寧可少報一個 technically correct 但實際沒有產品價值的問題，也不要為了找到問題而找問題。**
