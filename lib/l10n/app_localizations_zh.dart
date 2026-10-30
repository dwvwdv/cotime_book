// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Chinese (`zh`).
class AppLocalizationsZh extends AppLocalizations {
  AppLocalizationsZh([String locale = 'zh']) : super(locale);

  @override
  String get appName => '頁間';

  @override
  String get mastheadTagline => '不論相隔多遠，一起讀';

  @override
  String get pressBackAgainToExit => '再按一次返回鍵離開';

  @override
  String get activeRoom => '目前的房間';

  @override
  String get continueAction => '繼續';

  @override
  String get leaving => '正在離開...';

  @override
  String get leaveRoom => '離開房間';

  @override
  String get nickname => '暱稱';

  @override
  String get nicknameHint => '其他人要怎麼稱呼你？';

  @override
  String get back => '返回';

  @override
  String get joining => '正在加入...';

  @override
  String get joinRoom => '加入房間';

  @override
  String get creating => '正在建立...';

  @override
  String get createRoom => '建立房間';

  @override
  String get supabaseNotConfigured =>
      '尚未設定 Supabase。\n執行時加上 --dart-define=SUPABASE_URL=... --dart-define=SUPABASE_ANON_KEY=...';

  @override
  String get connected => '已連線';

  @override
  String get connecting => '正在連線...';

  @override
  String get tapToConnect => '點一下連線';

  @override
  String get enterNickname => '請輸入暱稱';

  @override
  String get leaveBeforeCreating => '請先離開目前的房間，再建立新房間。';

  @override
  String get enterValidRoomCode => '請輸入 6 個字元的房號';

  @override
  String get leaveBeforeJoining => '請先離開目前的房間，再加入其他房間。';

  @override
  String cleanupRoomMembership(String error) {
    return '房間成員資格：$error';
  }

  @override
  String cleanupRealtimePresence(String error) {
    return '即時連線狀態：$error';
  }

  @override
  String roomCleanupNeedsAttention(String errors) {
    return '離開房間時有些步驟沒有完成：$errors';
  }

  @override
  String get txtToEpub => 'TXT 轉 EPUB';

  @override
  String get moreApps => '更多 App';

  @override
  String get news => '公告';

  @override
  String get txtConvertIntro =>
      '把 TXT 檔做成 EPUB，先在這裡讀一遍，確認文字和章節沒問題。看起來對了再存檔，之後到房間裡分享存好的 EPUB。';

  @override
  String get pickTxtFiles => '選擇 TXT 檔';

  @override
  String get converted => '轉換完成';

  @override
  String get read => '閱讀';

  @override
  String get saving => '正在儲存...';

  @override
  String get saveAgain => '再存一次';

  @override
  String get saveEpub => '儲存 EPUB';

  @override
  String get savedShareInRoom => '已儲存。到房間裡點「分享書籍」，選這個檔案。';

  @override
  String get convertOtherFiles => '轉換其他檔案';

  @override
  String get opening => '正在開啟...';

  @override
  String get reading => '正在讀取...';

  @override
  String get converting => '正在轉換...';

  @override
  String get pickOnlyTxt => '只能選 TXT 檔。EPUB 不用轉換，直接在房間裡分享即可。';

  @override
  String txtSourcesTooLarge(int count, String size, String limit) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '檔案共 $size',
    );
    return '$_temp0。一本書最多只能用 $limit 的文字製作。';
  }

  @override
  String convertedBookTooLarge(String size, String limit) {
    return '轉出來的書有 $size。書最大只能是 $limit。';
  }

  @override
  String couldNotSaveEpub(String error) {
    return '無法儲存 EPUB：$error';
  }

  @override
  String get roomNotOnDevice => '這個裝置上沒有這個房間。';

  @override
  String roomLinkMismatch(String link, String code) {
    return '房間連結 $link 和你目前的房間 $code 不一致。';
  }

  @override
  String get unknownBook => '未知書名';

  @override
  String get roomClosed => '這個房間已經關閉。';

  @override
  String get roomInitCancelled => '已取消開啟房間。';

  @override
  String get authTimedOut => '登入逾時，請回到首頁再試一次。';

  @override
  String get openingRoom => '正在開啟房間...';

  @override
  String get roomNoLongerAvailable => '這個房間已經無法使用。';

  @override
  String get roomLobby => '房間大廳';

  @override
  String get leaveRoomTooltip => '離開房間';

  @override
  String get roomCodeOverline => '房號';

  @override
  String get members => '成員';

  @override
  String onlineCount(int count) {
    return '$count 人在線';
  }

  @override
  String get loading => '正在載入...';

  @override
  String get shareBook => '分享書籍';

  @override
  String get library => '圖書館';

  @override
  String get startReading => '開始閱讀';

  @override
  String get joinReading => '加入閱讀';

  @override
  String get reconnectingToRoom => '正在重新連上房間...';

  @override
  String get onlyHostCanStart => '只有房主可以開始閱讀。';

  @override
  String unableToStartReading(String error) {
    return '無法開始閱讀：$error';
  }

  @override
  String get readingStartedWaitForBook => '閱讀已經開始。書一傳到就可以加入。';

  @override
  String get bookNotOnDevice => '這本書還沒傳到這個裝置。';

  @override
  String get roomUnavailable => '無法進入房間';

  @override
  String get returnHome => '回到首頁';

  @override
  String get readyToRead => '可以開始讀了';

  @override
  String get receivingBook => '正在接收書籍...';

  @override
  String appOutOfDate(String names, int count, String appName) {
    return '你的 App 版本太舊：$names 用的是較新的版本。請更新「$appName」才能一起讀。';
  }

  @override
  String othersNeedUpdate(String names, int count, String appName) {
    return '$names 需要更新「$appName」才能一起讀。';
  }

  @override
  String get shareBookToStart => '分享一本書就能開始閱讀。';

  @override
  String get waitingForBookShare => '等待有人分享書籍。';

  @override
  String get bookOnItsWay => '書正在傳到這個裝置。';

  @override
  String get connectingToRoom => '正在連上房間...';

  @override
  String get hostStartsSession => '由房主開始閱讀。';

  @override
  String stillReceivingBook(String names, int count) {
    return '$names 還在接收書籍，書到了就能加入。';
  }

  @override
  String get listSeparator => '、';

  @override
  String get themePaper => '白紙';

  @override
  String get themeNight => '夜間';

  @override
  String get themeSepia => '米黃';

  @override
  String get couldNotChangeTextSize => '無法變更房間的字級，請稍後再試。';

  @override
  String get reader => '閱讀';

  @override
  String get openingBook => '正在開啟書籍...';

  @override
  String get noBookLoaded => '尚未載入書籍';

  @override
  String get backToLobby => '回到大廳';

  @override
  String get leaveReading => '離開閱讀';

  @override
  String get readingSettingsTooltip => '閱讀設定';

  @override
  String get readingSettings => '閱讀設定';

  @override
  String get settingsPage => '頁面外觀';

  @override
  String get settingsTextSize => '字級';

  @override
  String get textSizeTakesSeconds => '新的字級要幾秒才會出現：每位讀者的螢幕都要重新排版。請等頁面變了再點或翻頁。';

  @override
  String get onlyISetTextSize => '只有我能設定字級';

  @override
  String get onlyISetTextSizeHint => '關閉後每個人都能選字級，房間會採用所有人選的最大字級。';

  @override
  String get settingsTurningPages => '翻頁';

  @override
  String get volumeKeysTurnPages => '音量鍵翻頁';

  @override
  String get volumeKeysTurnPagesHint => '適用於翻頁鍵被當成音量鍵的電子閱讀器。';

  @override
  String get tapZonesHint => '點頁面左側三分之一回上一頁，其他地方到下一頁。Page Up/Down 與方向鍵也可以。';

  @override
  String get settingsTroubleshooting => '疑難排解';

  @override
  String get pageLayoutReport => '排版問題回報';

  @override
  String themeOptionLabel(String theme) {
    return '$theme主題';
  }

  @override
  String get youSetTextSize => '你為房間裡所有人設定字級。';

  @override
  String get hostSetsTextSize => '這個房間的字級由房主設定。';

  @override
  String get everyoneSeesSamePage => '每個人看到的是同一頁：頁面配合房間裡最小的螢幕，採用所有人選的最大字級。';

  @override
  String anotherReaderPickedSize(int size, String shared) {
    return '另一位讀者選了 $size，所以房間採用 $size。$shared';
  }

  @override
  String get roomMembers => '房間成員';

  @override
  String waitingForReconnect(String names) {
    return '等待 $names 重新連線...';
  }

  @override
  String get adBreakEllipsis => '廣告時間...';

  @override
  String adBreakWaitingFor(String names) {
    return '廣告時間：等待 $names...';
  }

  @override
  String readersReady(int count) {
    return '$count 位讀者已就緒';
  }

  @override
  String get synced => '已同步';

  @override
  String waitingForNames(String names) {
    return '等待 $names...';
  }

  @override
  String get wait => '等一下';

  @override
  String get go => '前往';

  @override
  String get turn => '翻頁';

  @override
  String waitingForOthersToConfirm(int confirmed, int required) {
    return '等待其他人確認... $confirmed/$required';
  }

  @override
  String get jumpingToPage => '正在跳到那一頁...';

  @override
  String get turningPage => '正在翻頁...';

  @override
  String get unknownMember => '未知';

  @override
  String wantsNextPage(String who) {
    return '$who 想翻到下一頁';
  }

  @override
  String wantsPreviousPage(String who) {
    return '$who 想翻回上一頁';
  }

  @override
  String wantsJumpElsewhere(String who) {
    return '$who 想跳到別頁';
  }

  @override
  String wantsJumpToPage(String who, String page) {
    return '$who 想跳到第 $page 頁';
  }

  @override
  String wantsJumpToPageWithProgress(String who, String page, String progress) {
    return '$who 想跳到第 $page 頁（$progress）';
  }

  @override
  String askToLeaveTooltip(String nickname) {
    return '請 $nickname 離開';
  }

  @override
  String askToLeaveTitle(String nickname) {
    return '要請 $nickname 離開嗎？';
  }

  @override
  String askToLeaveMessage(String nickname) {
    return '$nickname 會被移出房間，翻頁時大家就不用再等 $nickname。之後仍可以用房號重新加入。\n\n如果房裡還有其他人，要超過半數同意才行。';
  }

  @override
  String get askToLeave => '請對方離開';

  @override
  String removeMemberTitle(String nickname) {
    return '要移除 $nickname 嗎？';
  }

  @override
  String get voteIsOver => '這次表決已經結束。';

  @override
  String get close => '關閉';

  @override
  String removalVoteMessage(String voter, String target) {
    return '$voter 請 $target 離開房間，翻頁時大家就不用再等 $target。$target 之後仍可以用房號重新加入。';
  }

  @override
  String moreVotesNeeded(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '還需要 $count 票。',
    );
    return '$_temp0';
  }

  @override
  String get agree => '同意';

  @override
  String get notNow => '先不要';

  @override
  String couldNotAskToLeave(String nickname) {
    return '無法請 $nickname 離開，請再試一次。';
  }

  @override
  String memberRemoved(String nickname) {
    return '$nickname 已被移出房間。';
  }

  @override
  String memberGone(String nickname) {
    return '$nickname 已經不在房間裡。';
  }

  @override
  String voteIn(int count, String nickname) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '已投票。還需要 $count 票才能移除 $nickname。',
    );
    return '$_temp0';
  }

  @override
  String get cancel => '取消';

  @override
  String get noMembersYet => '還沒有成員';

  @override
  String get needsAppUpdate => '需要更新 App';

  @override
  String get newerAppUpdateYours => '對方 App 較新，請更新你的';

  @override
  String get youSuffix => '  （你）';

  @override
  String get online => '在線';

  @override
  String get awayNotConnected => '離開：未連線';

  @override
  String get hasBook => '有書';

  @override
  String get noBook => '沒有書';

  @override
  String membersOnline(int count) {
    return '$count 位成員在線';
  }

  @override
  String get statusReading => '閱讀中';

  @override
  String get statusLeftReader => '已離開閱讀';

  @override
  String get statusNotConnected => '未連線';

  @override
  String get adBreakPageOpensWhenBack => '等所有讀者回來就會打開這一頁。';

  @override
  String adBreakWaitingForAd(String names) {
    return '等待 $names 看完廣告...';
  }

  @override
  String get adBreak => '廣告時間';

  @override
  String get ads => '廣告';

  @override
  String get adPrivacyChoices => '廣告隱私選項';

  @override
  String get adPrivacyChoicesHint => '變更你對這個 App 廣告的同意設定。';

  @override
  String get announcementsLoadFailed => '無法載入公告。';

  @override
  String get tryAgain => '再試一次';

  @override
  String get noAnnouncements => '目前沒有公告。';

  @override
  String get contents => '目錄';

  @override
  String contentsEntries(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count 項',
    );
    return '$_temp0';
  }

  @override
  String get noContents => '這本書沒有目錄。';

  @override
  String get untitled => '（未命名）';

  @override
  String get stillWorkingOutLength => '還在計算這本書的長度，請稍後再試。';

  @override
  String get jumpPageLabel => '頁碼';

  @override
  String get jumpHere => '在這頁';

  @override
  String get previousPage => '上一頁';

  @override
  String get nextPage => '下一頁';

  @override
  String get positionInBook => '在書中的位置';

  @override
  String get reportRateLimited => '過去一小時內送出的回報太多了，請稍後再試。';

  @override
  String get reportSendFailed => '無法送出回報，請再試一次。';

  @override
  String get pageLayoutReportTitle => '排版問題回報';

  @override
  String get pageLayoutReportIntro =>
      '如果頁面被切掉或翻頁跳過了內容，請在發生後馬上送出。回報裡只有這個螢幕怎麼排版、你讀到書的哪裡，不會有書的內文。';

  @override
  String get reportNoteHint => '發生了什麼問題？（選填）';

  @override
  String get reportSentToHistory => '已送出。可以在首頁的「回報紀錄」查看處理進度。';

  @override
  String get sending => '正在送出...';

  @override
  String get sendReport => '送出回報';

  @override
  String get reportHistory => '回報紀錄';

  @override
  String reportHistoryUpdates(int count) {
    return '你有 $count 筆回報有了處理結果';
  }

  @override
  String get reportHistoryEmpty => '你還沒有送出任何回報。';

  @override
  String get reportHistoryLoadFailed => '無法載入你的回報。請確認網路連線後再試一次。';

  @override
  String get reportStatusOpen => '待處理';

  @override
  String get reportStatusResolved => '已解決';

  @override
  String get reportStatusUpdateNeeded => '需要更新';

  @override
  String get reportStatusDeclined => '不處理';

  @override
  String reportFixedIn(String version) {
    return '已在 $version 修正';
  }

  @override
  String reportUpdateForFix(String version) {
    return '已在 $version 修正，請更新 App 取得修正。';
  }

  @override
  String reportSentAt(String time) {
    return '回報時間：$time';
  }

  @override
  String reportHandledAt(String time) {
    return '處理時間：$time';
  }

  @override
  String get reportUnknownBook => '未記錄書名';

  @override
  String reportYourNote(String note) {
    return '你的說明：$note';
  }

  @override
  String get languageChineseTraditional => '中文（繁體）';

  @override
  String get languageChineseSimplified => '中文（簡體）';

  @override
  String get languageChinese => '中文';

  @override
  String get languageEnglish => '英文';

  @override
  String get languageJapanese => '日文';

  @override
  String get languageKorean => '韓文';

  @override
  String get languageFrench => '法文';

  @override
  String get languageGerman => '德文';

  @override
  String get languageSpanish => '西班牙文';

  @override
  String get languageItalian => '義大利文';

  @override
  String get languagePortuguese => '葡萄牙文';

  @override
  String get languageRussian => '俄文';

  @override
  String get languageLatin => '拉丁文';

  @override
  String get languageGreek => '希臘文';

  @override
  String get languageDutch => '荷蘭文';

  @override
  String get languageVietnamese => '越南文';

  @override
  String get languageThai => '泰文';

  @override
  String get libraryOpenFailed => '無法開啟圖書館。';

  @override
  String get libraryNoteLoadFailed => '無法載入說明。';

  @override
  String get publicLibrary => '公共圖書館';

  @override
  String get aboutTheseBooks => '關於這些書';

  @override
  String get searchByTitleOrAuthor => '用書名或作者搜尋';

  @override
  String get clearSearch => '清除搜尋';

  @override
  String get books => '書籍';

  @override
  String bookCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count 本書',
    );
    return '$_temp0';
  }

  @override
  String shownOfBooks(int shown, String total) {
    return '$total中的 $shown 本';
  }

  @override
  String get loadingLibrary => '正在載入圖書館...';

  @override
  String get libraryEmpty => '圖書館目前還沒有書。';

  @override
  String get noBooksMatch => '沒有符合的書。';

  @override
  String get clearSearchAndFilters => '清除搜尋與篩選';

  @override
  String get filters => '篩選';

  @override
  String get tags => '標籤';

  @override
  String get booksWithAnyTag => '符合任一標籤的書';

  @override
  String get language => '語言';

  @override
  String get all => '全部';

  @override
  String get noNoteYet => '目前還沒有說明。';

  @override
  String get aboutTheseBooksOverline => '關於這些書';

  @override
  String get getItOnGooglePlay => '到 Google Play 下載';

  @override
  String get googlePlayCouldNotOpen => '這個裝置無法開啟 Google Play。連結：';

  @override
  String get goToPage => '跳到指定頁';

  @override
  String pageCounterLabel(int page, int pages) {
    return '本章第 $page 頁，共 $pages 頁';
  }

  @override
  String pageCounterProgress(String progress) {
    return '，全書的 $progress';
  }

  @override
  String get pageCounterGoTo => '。跳到指定頁';

  @override
  String get dismiss => '關閉';

  @override
  String get recentRooms => '最近的房間';

  @override
  String get noBookYet => '還沒有書';

  @override
  String recentRoomSubtitle(String book, String visit) {
    return '$book · $visit';
  }

  @override
  String removeFromRecentRooms(String code) {
    return '從最近的房間移除 $code';
  }

  @override
  String get today => '今天';

  @override
  String get yesterday => '昨天';

  @override
  String daysAgo(int days) {
    return '$days 天前';
  }

  @override
  String roomCodeSemantics(String code) {
    return '房號 $code。點一下複製。';
  }

  @override
  String get roomCodeCopied => '已複製房號';

  @override
  String get tapToCopy => '點一下複製';

  @override
  String get roomCode => '房號';

  @override
  String get waitingForTheBook => '等待書籍';

  @override
  String get sendingBook => '正在傳送書籍...';

  @override
  String get bookSent => '書已送出';

  @override
  String get bookReceived => '書已收到';

  @override
  String get missedPartsWillAsk => '漏收的人會再要剩下的部分。';

  @override
  String get readyToReadSentence => '可以開始讀了。';

  @override
  String get makeBookFromTxt => '用 TXT 做一本書';

  @override
  String txtFilesBecomeOneEpub(int count) {
    return '這 $count 個檔案會依這個順序合成一本 EPUB。存檔前可以先讀。';
  }

  @override
  String get txtFileBecomesEpub => '這個檔案會轉成 EPUB。存檔前可以先讀。';

  @override
  String get title => '書名';

  @override
  String get authorOptional => '作者（選填）';

  @override
  String get files => '檔案';

  @override
  String get file => '檔案';

  @override
  String get splitByLength => '依長度分段';

  @override
  String get noChaptersFound => '找不到章節';

  @override
  String chapterCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count 章',
    );
    return '$_temp0';
  }

  @override
  String get splitIntoChapters => '分成章節';

  @override
  String get splitIntoChaptersHint => '如果有不是章節標題的行被當成標題，就關掉這個選項，改成依長度分段。';

  @override
  String get makeEpub => '製作 EPUB';

  @override
  String get noTextInEncoding => '用這個編碼讀不到文字，會略過這個檔案';

  @override
  String characterCount(String count) {
    return '$count 字';
  }

  @override
  String splitByLengthWithCharacters(String characters) {
    return '依長度分段 · $characters';
  }

  @override
  String noChapterHeadingsWithCharacters(String characters) {
    return '沒有章節標題，依長度分段 · $characters';
  }

  @override
  String chaptersWithCharacters(String chapters, String characters) {
    return '$chapters · $characters';
  }

  @override
  String get textEncoding => '文字編碼';

  @override
  String encodingLabel(String encoding) {
    return '編碼：$encoding';
  }

  @override
  String get moveUp => '上移';

  @override
  String get moveDown => '下移';

  @override
  String get previous => '上一頁';

  @override
  String get next => '下一頁';

  @override
  String onlyYouSeeThis(int percent) {
    return '只有你看得到 · $percent%';
  }

  @override
  String pageNotFound(String uri) {
    return '找不到頁面：$uri';
  }

  @override
  String get invalidRoomLink => '房間連結無效';

  @override
  String get joinFromHomeFirst => '請先從首頁加入這個房間，再開啟這個頁面。';

  @override
  String get notEpub => '只能分享 EPUB 書籍。請先在首頁用「TXT 轉 EPUB」把 TXT 檔轉成 EPUB。';

  @override
  String libraryDownloadFailed(String title, String error) {
    return '無法從圖書館取得《$title》：$error';
  }

  @override
  String get bookFileEmpty => '書籍檔案是空的';

  @override
  String bookTooLarge(String size, String limit) {
    return '這本書有 $size。書最大只能是 $limit。';
  }

  @override
  String get membershipInactive => '你在這個房間的成員資格已失效或過期。';

  @override
  String get roomStateChanged => '房間狀態在更新完成前就變了';

  @override
  String roomNoLongerAvailableCode(String code) {
    return '房間 $code 已經無法使用。';
  }

  @override
  String get roomUpdatedByAnotherClient => '房間狀態已被其他裝置更新';

  @override
  String get notAuthenticated => '尚未登入';

  @override
  String get removedFromRoom => '你已經不在這個房間了。房間可能已關閉，或你在另一台裝置上離開了。';

  @override
  String get removedByVote => '其他讀者把你移出了這個房間。你可以用房號重新加入。';

  @override
  String get bookStillLoading => '書還在載入中';

  @override
  String get reconnectingTryAgain => '正在重新連上房間，請稍後再試';

  @override
  String get stillConnecting => '還在連上房間';

  @override
  String waitingForReconnectShort(String names) {
    return '等待 $names 重新連線';
  }

  @override
  String get waitingForAdBreak => '等待廣告時間結束';

  @override
  String waitingForAdShort(String names) {
    return '等待 $names 看完廣告';
  }

  @override
  String get couldNotReachReaders => '無法連絡其他讀者';

  @override
  String get couldNotSendAnswer => '無法送出你的回應，請再試一次。';

  @override
  String get turnRequestExpired => '翻頁請求已過期';

  @override
  String turnTimedOutWaitingFor(String names) {
    return '翻頁逾時：還在等 $names';
  }

  @override
  String othersNeedAppUpdate(String names, int count) {
    return '$names 需要更新 App 才能一起讀';
  }

  @override
  String updateAppToReadWith(String names) {
    return '請更新 App 才能和 $names 一起讀';
  }

  @override
  String get sentenceSeparator => '。';

  @override
  String get cancelTimeout => '翻頁逾時：其他讀者沒有回應';

  @override
  String get cancelOutOfSync => '讀者停在不同頁，已重新同步，請再試一次';

  @override
  String get cancelRequesterLeft => '翻頁已取消：發起的人離開了';

  @override
  String get cancelSuperseded => '另一個翻頁請求先送出了';

  @override
  String get cancelTurnFailed => '頁面沒有移動，可能已在書的開頭或結尾';

  @override
  String get cancelJumpFailed => '無法跳到那一頁，請再試一次';

  @override
  String get cancelRequesterBusy => '翻頁已取消：頁面還在載入';

  @override
  String get cancelReaderDisconnected => '翻頁暫停：有讀者正在重新連線';

  @override
  String get cancelAdBreak => '翻頁暫停：廣告時間還沒結束';

  @override
  String get readerAskedToWait => '有讀者想在這一頁多停一下';

  @override
  String nicknameAskedToWait(String nickname) {
    return '$nickname 想在這一頁多停一下';
  }

  @override
  String get turnCancelled => '翻頁已取消';

  @override
  String othersNeedUpdateToJump(String names, int count) {
    return '$names 需要更新 App 才能跳頁';
  }

  @override
  String get waitingForTheBookEllipsis => '等待書籍...';

  @override
  String get bookArrivedDamaged => '收到的書損毀了，正在重新要一次...';

  @override
  String get downloadingFromLibrary => '正在從圖書館下載書籍...';

  @override
  String gettingBookFrom(String nickname) {
    return '正在從 $nickname 取得書籍...';
  }

  @override
  String get waitingForHolder => '等待有這本書的人上線...';

  @override
  String askingForBook(String nickname) {
    return '正在向 $nickname 要書...';
  }

  @override
  String get anotherReader => '另一位讀者';

  @override
  String get aReader => '一位讀者';

  @override
  String get switchLanguage => 'English';

  @override
  String get switchLanguageTooltip => '切換成英文';

  @override
  String get txtNeedsTitle => '書需要書名。';

  @override
  String get txtPickAtLeastOne => '請至少選一個 TXT 檔。';

  @override
  String get txtNoText => '這些檔案裡沒有文字。';

  @override
  String cannotReadFile(String fileName) {
    return '無法讀取 $fileName';
  }
}
