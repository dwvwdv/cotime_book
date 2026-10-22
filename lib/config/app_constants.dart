class AppConstants {
  // Room
  static const int roomCodeLength = 6;
  static const String roomCodeChars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';

  // Page sync
  static const Duration pageTurnTimeout = Duration(seconds: 30);

  // File transfer
  // 32KB raw → ~43KB base64; safe within Supabase Realtime broadcast limit
  static const int fileChunkSize = 32 * 1024;
  // Large enough for illustrated books; a 40MB book is ~1280 broadcasts, which
  // is why library books are downloaded straight from Storage instead.
  static const int maxFileSize = 40 * 1024 * 1024;
  static const Duration chunkDelay = Duration(milliseconds: 100);

  // Public library: a Storage bucket of EPUBs anyone can list and download.
  // Must match the bucket created in supabase/migrations.
  static const String libraryBucket = 'cotime-book-library';

  // Realtime
  static String roomChannelName(String roomCode) => 'cotime_book:room:$roomCode';

  /// The version of the room's wire protocol — broadcast events and their
  /// payloads, and the Presence fields others act on. Sent in Presence so a
  /// room can tell members whose app speaks a different version apart:
  /// otherwise both sides silently ignore each other (GH-33).
  ///
  /// Bump it in the same change that alters the wire in a way an app on the
  /// previous version cannot follow (renamed or removed events, payload or
  /// Presence fields it relies on). Additive, ignorable fields do not need a
  /// bump. Apps from before this field existed send nothing and count as 0.
  static const int roomProtocolVersion = 1;
}
