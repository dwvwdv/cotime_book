import '../models/page_sync_state.dart';

/// Collapses multiple device/connection metas into one logical room member.
///
/// Supabase Presence is keyed per connection, so one logical user can appear
/// several times: a second device, or a meta that has not expired yet after a
/// reconnect. Every consumer must agree on one row per `user_id`, otherwise the
/// page-turn quorum and the lobby roster disagree about who is ready.
///
/// Boolean readiness is true when any live session reports it; display data is
/// taken from the most recently tracked session.
List<Map<String, dynamic>> mergePresenceUsers(
  Iterable<Map<String, dynamic>> presenceUsers,
) {
  final grouped = <String, List<Map<String, dynamic>>>{};
  for (final user in presenceUsers) {
    final userId = user['user_id'];
    if (userId is! String || userId.isEmpty) continue;
    grouped.putIfAbsent(userId, () => []).add(user);
  }

  final merged = <Map<String, dynamic>>[];
  for (final entry in grouped.entries) {
    final metas = entry.value;
    metas.sort((a, b) => presenceTime(b).compareTo(presenceTime(a)));
    final latest = Map<String, dynamic>.from(metas.first);
    latest['user_id'] = entry.key;
    latest['has_book'] = metas.any((meta) => meta['has_book'] == true);
    latest['ready_book_hashes'] = metas
        .where((meta) => meta['has_book'] == true)
        .map((meta) => meta['book_hash'])
        .whereType<String>()
        .toSet()
        .toList(growable: false);
    latest['is_reading'] = metas.any((meta) => meta['is_reading'] == true);
    latest['reader_ready'] = metas.any((meta) => meta['reader_ready'] == true);
    _mergeReadingPosition(latest, metas);
    latest['session_count'] = metas.length;
    merged.add(latest);
  }

  merged.sort((a, b) {
    final timeOrder = presenceTime(a).compareTo(presenceTime(b));
    if (timeOrder != 0) return timeOrder;
    return (a['user_id'] as String).compareTo(b['user_id'] as String);
  });
  return List.unmodifiable(merged);
}

/// The newest page any of this user's reading connections holds.
///
/// Taken from reading metas only: a lobby meta's position is whatever page that
/// connection last saw, and must not drag the merged row backwards. Ordered by
/// [SharedPosition.isNewerThan], the same order [PageSyncService] converges on.
void _mergeReadingPosition(
  Map<String, dynamic> merged,
  List<Map<String, dynamic>> metas,
) {
  merged
    ..remove('page_epoch')
    ..remove('page_seq')
    ..remove('page_cfi');
  SharedPosition? newest;
  for (final meta in metas) {
    if (meta['is_reading'] != true) continue;
    final position = SharedPosition.fromPresence(meta);
    if (position == null) continue;
    if (newest == null || position.isNewerThan(newest)) newest = position;
  }
  if (newest != null) {
    merged['page_epoch'] = newest.epoch;
    merged['page_seq'] = newest.seq;
    merged['page_cfi'] = newest.cfi;
  }
}

/// Whether a merged Presence row holds the book [bookHash] — i.e. can serve
/// it, and has it ready to read.
bool presenceHoldsBook(Map<String, dynamic> user, String bookHash) {
  final hashes = user['ready_book_hashes'];
  return hashes is List && hashes.contains(bookHash);
}

DateTime presenceTime(Map<String, dynamic> presence) {
  return DateTime.tryParse(presence['online_at'] as String? ?? '') ??
      DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
}
