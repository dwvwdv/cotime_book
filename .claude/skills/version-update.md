# 版本更新流程

## 何時使用

改到「會出貨到使用者手上的東西」時使用此流程：

- `lib/`、`assets/`、`android/` 的任何功能調整或 bug 修復
- 依賴升級（`pubspec.yaml` 的 dependencies）
- 會改變房間行為的 Supabase migration（舊版 App 會連到同一個正式庫，見 issue #K）

⚠️ **每次功能調整或修復都必須更新版本號。**

只動 `CLAUDE.md`、`issue.md`、`README.md`、`.claude/`、`.github/` 這類**不進 APK** 的 PR
不需要 bump——版本碼是 Google Play 的稀缺資源（每次上傳都要新的），而這些 PR 的產物
與上一版完全相同。

⚠️ **同一個 PR 最多只疊代一次版本號**：PR 的首個（需要 bump 的）commit 將版本 +1 之後，
同一 PR 的後續 commit（review 修復、追加調整）沿用同一版號、不再遞增；changelog 也合併
記在同一版本條目下。禁止在單一 PR 內出現 vX → vX+1 → vX+2 的連續疊代。

## 版本號格式

`major.minor.patch+build`（例如：`1.0.1+5`）

- **唯一來源是 `pubspec.yaml` 的 `version:`**。Gradle 從這裡拿 `versionName` / `versionCode`，
  CI（`release-apk.yml` 的 tag、`publish-play-store.yml` 的版本碼）也直接從這裡讀。
  不要在別處寫死版號。
- `+build` 就是 Google Play 的 **versionCode**，必須嚴格遞增；同一個版本碼上傳第二次會被拒收。

## 具體步驟

### 1. 更新版本號

- **除非特別指定，否則只增加 `patch`**：`1.0.0` → `1.0.1`
- **每次都要增加 `build`**：`+4` → `+5`

### 2. 更新 changelog

在 `.claude/skills/changelog.md` 最上方新增（或併入本 PR 已建立的）版本條目，
格式見該檔開頭。

### 3. 提交

版號可以跟功能改動放在同一個 commit；分開的話：

```bash
git commit -m "chore: 更新版本號至 x.x.x+x"
```

## 驗證

```bash
flutter pub get
flutter analyze --no-fatal-infos
flutter test
```

`release-apk.yml` 合併進 master 後會以 `v<version>` 為 tag 建 GitHub Release；忘記 bump 時
這個 tag 已經存在，新 build 會被掛到上一版的 release 底下，而不是開一個新的。

## 常見問題

### Q: 只改了一個小 bug，也要更新版本號嗎？
A: 要。任何會進 APK 的改動都要，否則無法從版號分辨使用者手上的是哪一版。

### Q: build 號忘了加、或 Play Console 說版本碼已被使用？
A: 補一個 commit 把 `+N` 調高即可。若只是要重新上傳同一份程式碼，也可以在觸發
`publish-play-store.yml` 時填 `version_code` 覆蓋，不必改 `pubspec.yaml`。

### Q: 版本碼已經在 Play 上，只是要換軌道（internal → production）？
A: 觸發 `publish-play-store.yml` 時勾 `skip_build`，填該 `version_code`，直接 promote，不重新編譯。

## 範例

```
修改前: 1.0.0+4
修改後: 1.0.1+5
```
