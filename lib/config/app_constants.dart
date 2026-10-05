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
}
