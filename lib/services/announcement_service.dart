import '../models/announcement.dart';
import 'supabase_service.dart';

/// The announcements shown from the home screen.
///
/// Injectable so the home screen can be tested without the network.
abstract interface class AnnouncementService {
  /// Published announcements, newest first.
  Future<List<Announcement>> list();
}

/// Reads `cotime_book.announcements`. The table's policy only returns rows
/// whose time has come, so a note written ahead of a release stays hidden.
class SupabaseAnnouncementService implements AnnouncementService {
  /// Old notes stop being news; the sheet only needs the recent ones.
  static const listLimit = 30;
  static const listTimeout = Duration(seconds: 30);

  final Future<List<Map<String, dynamic>>> Function() _readTable;

  SupabaseAnnouncementService({
    Future<List<Map<String, dynamic>>> Function()? readTable,
  }) : _readTable = readTable ?? _readAnnouncementsTable;

  static Future<List<Map<String, dynamic>>> _readAnnouncementsTable() async {
    return SupabaseService.database
        .from('announcements')
        .select('id, title, content, published_at')
        .order('published_at', ascending: false)
        .limit(listLimit);
  }

  @override
  Future<List<Announcement>> list() async {
    final rows = await _readTable().timeout(listTimeout);
    return [for (final row in rows) ?Announcement.fromRow(row)];
  }
}
