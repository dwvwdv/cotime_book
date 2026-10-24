class AppConstants {
  // The app's name. The Chinese name is the official one; the English name
  // stays for the launcher of non-Chinese devices (android res/values) and
  // the English UI text that names the app.
  static const String appName = '頁間';
  static const String appNameEnglish = 'CoTime Book';

  // Room
  static const int roomCodeLength = 6;
  static const String roomCodeChars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';

  // Page sync
  static const Duration pageTurnTimeout = Duration(seconds: 30);

  // File transfer
  // 32KB raw → ~43KB base64; safe within Supabase Realtime broadcast limit
  static const int fileChunkSize = 32 * 1024;
  // Large enough for illustrated books; a 40MB book is ~1280 broadcasts, which
  // is why library books are downloaded straight from the library instead.
  static const int maxFileSize = 40 * 1024 * 1024;
  static const Duration chunkDelay = Duration(milliseconds: 100);

  /// Whether this app sends and fetches books over a direct WebRTC
  /// connection, with the Realtime broadcast above as the fallback (GH-60).
  /// Announced in Presence as `direct_transfer`.
  static const bool directBookTransfer = true;

  /// Supabase Edge Function that hands out short-lived TURN credentials
  /// (supabase/functions/turn-credentials). Without it, direct connections
  /// use STUN only and fall back to Realtime more often.
  static const String turnCredentialsFunction = 'turn-credentials';

  // Public library: a pCloud public folder of EPUBs anyone can list and
  // download. The maintainers add books by putting them in the folder and
  // describe them in cotime_book.library_books. Paths in the catalog and in
  // rooms.current_book_library_path are relative to this folder.
  static const String libraryUrl =
      'https://filedn.eu/lyWyjTiBuD9uWONu3Or0JNX/lazyrhythm/CotimeBook/eBook/';

  // Where the library's books come from and their copyright status, shown by
  // the library's help button. A plain UTF-8 text file in the library folder.
  static const String libraryNoticeFile = '書籍來源聲明.txt';

  // Realtime
  static String roomChannelName(String roomCode) =>
      'cotime_book:room:$roomCode';

  /// The version of the room's wire protocol — broadcast events and their
  /// payloads, and the Presence fields others act on. Sent in Presence so a
  /// room can tell members whose app speaks a different version apart:
  /// otherwise both sides silently ignore each other (GH-33).
  ///
  /// Bump it in the same change that alters the wire in a way an app on the
  /// previous version cannot follow (renamed or removed events, payload or
  /// Presence fields it relies on), or that changes where the shared page
  /// breaks: a commit names a page by this app's page breaks, and an app that
  /// breaks the same book elsewhere shows another page. Additive, ignorable
  /// fields do not need a bump. Apps from before this field existed send
  /// nothing and count as 0.
  ///
  /// 2: chapters in a clipping wrapper are laid out across pages (GH-49) and
  /// lines too long for the page wrap (GH-52). An app on 1 squeezes such a
  /// chapter into one page and turns straight to the next chapter.
  static const int roomProtocolVersion = 2;

  /// The oldest [roomProtocolVersion] this app still reads together with,
  /// also sent in Presence. Members below it are told to update; an app whose
  /// own minimum is above this app's version tells this one to update.
  ///
  /// Raise it to the new version when a bump is one the previous apps cannot
  /// follow, as version 2's page breaks are not.
  static const int minCompatibleRoomProtocol = 2;
}
