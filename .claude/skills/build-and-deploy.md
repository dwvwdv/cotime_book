# 構建與部署流程

## 何時使用

- 首次設置開發環境（含 Claude Code 雲端 session）
- 送 PR 前的本機檢查
- 構建 APK / AAB、上架 Google Play
- 調整 CI workflow（先讀最後的「CI 設計筆記」）

## 1. 環境設置

### Flutter 版本

**以 CI 為準**：`.github/workflows/*.yml` 的 `flutter-version`（目前 `3.32.4`）。
`.claude/hooks/session-start.sh` 釘的是同一個版本——**升級 Flutter 時三份 workflow 與 hook 要一起改**，
否則本機 `flutter analyze` 乾淨、CI 卻報新版 lint（或反過來）。

Claude Code 雲端 session 由 SessionStart hook 自動安裝（只在 `CLAUDE_CODE_REMOTE=true` 時執行），
並跑一次 `flutter pub get`；本機開發自行安裝同版本即可。

```bash
flutter doctor
flutter pub get
```

### Supabase

```bash
supabase db reset      # 重放 supabase/migrations/
supabase test db       # pgTAP（supabase/tests/）
```

正式庫套用 migration 的注意事項見 `CLAUDE.md` 的「指令」。

## 2. 送 PR 前的檢查

```bash
flutter analyze --no-fatal-infos   # 必須乾淨
flutter test                       # 必須全綠
supabase test db                   # 動到 supabase/ 時
node tool/shared_page_check/check.js   # 動到 displaySettings / SharedPageStyle / shared_page.js 時
```

`shared_page_check` 需要 Playwright 的 Chromium 與幾套系統字型（見 `check.js` 開頭），
**CI 沒有跑它**——改到共享頁面排版時只能靠本機這一步擋下兩台裝置分頁不一致。

## 3. 執行與構建

Supabase 憑證一律用 `--dart-define` 傳，**不要寫進原始碼或 commit 進 repo**：

```bash
flutter run \
  --dart-define=SUPABASE_URL=https://your-project.supabase.co \
  --dart-define=SUPABASE_ANON_KEY=your-anon-key

# Release APK（CI 只出 arm64）
flutter build apk --release --target-platform android-arm64 \
  --dart-define=SUPABASE_URL=... --dart-define=SUPABASE_ANON_KEY=...

# Google Play 用的 AAB
flutter build appbundle --release \
  --dart-define=SUPABASE_URL=... --dart-define=SUPABASE_ANON_KEY=...
```

少了 `--dart-define` 的 build 照樣編得過、裝得起來，只是連不上房間（"Supabase not configured"）。

輸出位置：

```
build/app/outputs/flutter-apk/app-release.apk
build/app/outputs/bundle/release/app-release.aab
```

簽章：CI 從 `KEYSTORE_BASE64` 等 secrets 產生 `android/key.properties` 與
`android/app/release-key.jks`（兩者都在 `.gitignore`）。沒有 keystore 時 build-check 退回 debug APK。

## 4. CI workflow 一覽

| Workflow | 觸發 | 做什麼 |
| --- | --- | --- |
| `build-check.yml` | PR（paths 過濾）、手動 | pgTAP ‖ analyze + test + arm64 APK（平行兩個 job） |
| `release-apk.yml` | push master、手動 | analyze + test → APK / AAB → GitHub Release（tag = `v<pubspec version>`） |
| `publish-play-store.yml` | 手動 | 編 AAB 上傳 Google Play，或 `skip_build` 直接 promote 既有版本碼 |
| `test-signing.yml` | 手動 | 比對 CI keystore 與另一份 keystore 的 SHA256 指紋 |

`publish-play-store.yml` 的 inputs 與所需 secrets 見 README 的 "Publishing to Google Play"。
每次上傳都要新的版本碼（見 `version-update.md`）。

### 可調的 repository variables

| 變數 | 作用 |
| --- | --- |
| `CI_RUNNER` | 主要 job 的 runner（未設定時 `ubuntu-latest`），可指向 self-hosted runner |
| `CI_LIGHT_RUNNER` | 輕量 job（pgTAP）的 runner，未設定時 `ubuntu-latest` |
| `SKIP_COMPILER` | 設成 `true` 時 build-check 只跑 analyze + test、不編 APK（runner 吃緊或只想快速驗證時） |

## 5. CI 設計筆記

這些規則是從無感記帳（seamless_track）的 CI 搬過來的，每一條都對應一次真實踩過的坑。
改 workflow 前先看過；workflow 檔內也有對應的註解。

- **paths 過濾要涵蓋所有會影響結果的來源。** PR 只改了沒列進去的目錄時，workflow
  完全不觸發，PR 看起來是「沒有 check」而不是紅的。本專案的 `assets/reader/shared_page.js`
  就是例子——它決定全房的排版，卻曾經不在清單裡（issue #W）。新增會進 APK 或被測試讀到的目錄時，
  這裡要跟著加；`test/ci_workflow_test.dart` 會擋下漏列的 asset。
- **build-check 要有 `workflow_dispatch`。** branches 過濾配上預設的
  `opened / synchronize / reopened`，會漏掉「PR 開在別的 base、之後才改指向 master」：
  改 base 只發 `edited`，workflow 一次都不會跑。手動觸發是唯一的補救。
- **`concurrency` + `cancel-in-progress`。** 同一個 PR 連續 push 時取消舊的 run，只保留最新一次。
  只用在 build-check；release / publish **不要**加 cancel——中途取消上傳可能留下半套 release。
- **Telegram 通知一律 best effort。** curl 加 `--connect-timeout 10 --max-time 30 --fail-with-body`
  （沒有逾時的話一個卡住的上傳能吃掉整個 job 的 timeout）；上傳 APK 失敗時改送 GitHub
  artifact 的下載連結；整段失敗也不讓 job 變紅。因此 **artifact 要在 Telegram 之前上傳**，
  才拿得到 `artifact-id`。
- **release-apk 對純文件 push 不觸發**（`paths-ignore: '**/*.md'`, `.claude/**`）：
  它會用 pubspec 的版號建 tag，文件改動觸發只會把同一份 build 再掛一次到同一個 release 上。
- **`flutter test --timeout 2m`。** 預設的單測逾時很長，一個卡死的非同步測試會一路等到
  job timeout 才失敗，而且看不出是哪一個。
- **會吃大量磁碟的步驟拆成獨立 job，不要塞在 APK build 前面。** 無感記帳曾把 Robolectric
  測試和 APK build 放在同一個 runner 上，APK build 在下載 AGP 依賴時撞到
  "No space left on device"。清理 step 治標不治本；拆成平行 job 順便縮短總時間。
  （本專案的 pgTAP 已經是獨立 job。）
- **不要用 `--tests` 指名要跑的測試類別。** 新增測試時很容易忘了回頭改 workflow，
  症狀是「CI 全綠但那個檔案從來沒被執行過」。

### 尚未套用、可以再考慮的

- **Flutter 升級到 3.38.x**（無感記帳已在用）：要同時改三份 workflow、session-start hook，
  並確認 `flutter analyze` 沒有新的 lint 與 `flutter test` 全綠。
- **CI 跑 `tool/shared_page_check`**（issue #X）：需要 Playwright Chromium 與 CJK 字型，安裝成本不低；
  可做成只在 `assets/reader/**`、`lib/services/shared_page*.dart` 變動時觸發的獨立 job。
- **`publish-play-store.yml` 的發版說明改從檔案讀**：無感記帳從 `assets/announcement.json`
  第一筆的 `release_notes` 帶入，App 內公告與 Play 說明同一份來源。本專案目前沒有 App 內公告，
  維持手動輸入。

## 常見問題

### 構建失敗

```bash
flutter clean
flutter pub get
flutter build apk --release
```

Gradle 本身出問題時再加 `cd android && ./gradlew clean`。

### Play Console 拒收

- 「版本碼已被使用」：調高 `pubspec.yaml` 的 `+N`，或觸發時填 `version_code`
- 「以 debug key 簽署」：`KEYSTORE_BASE64` 沒設；publish workflow 會在編譯前擋下
- 「draft app 不能 completed release」：首次審核通過前 `release_status` 選 `draft`
