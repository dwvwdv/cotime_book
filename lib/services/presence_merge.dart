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
/// connection last saw, and must not drag the merged row backwards.
void _mergeReadingPosition(
  Map<String, dynamic> merged,
  List<Map<String, dynamic>> metas,
) {
  merged.remove('page_seq');
  merged.remove('page_cfi');
  int? bestSeq;
  String? bestCfi;
  for (final meta in metas) {
    final seq = meta['page_seq'];
    final cfi = meta['page_cfi'];
    if (meta['is_reading'] != true || seq is! int || cfi is! String) continue;
    final isNewer =
        bestSeq == null ||
        seq > bestSeq ||
        (seq == bestSeq && cfi.compareTo(bestCfi!) > 0);
    if (isNewer) {
      bestSeq = seq;
      bestCfi = cfi;
    }
  }
  if (bestSeq != null) {
    merged['page_seq'] = bestSeq;
    merged['page_cfi'] = bestCfi;
  }
}

DateTime presenceTime(Map<String, dynamic> presence) {
  return DateTime.tryParse(presence['online_at'] as String? ?? '') ??
      DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
}
