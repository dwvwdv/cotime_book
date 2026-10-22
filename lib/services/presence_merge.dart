import '../config/app_constants.dart';
import '../models/shared_page.dart';

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
    // Every device this person reads on shows the same page, so the page has
    // to fit all of them — not just the one that tracked last.
    latest['page_fit'] = PageFit.combine(
      metas
          .where((meta) => meta['is_reading'] == true)
          .map((meta) => PageFit.fromWire(meta['page_fit']))
          .whereType<PageFit>(),
    )?.toWire();
    // Every protocol this person's connections speak, not the latest one: a
    // person can follow the room on any device that understands it, and an
    // expired meta from before an app update must not make them look out of
    // date. See [presenceProtocolCompatibility].
    latest.remove('protocol');
    latest['protocols'] = (metas.map(presenceProtocol).toSet().toList()
      ..sort());
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

/// Whether a merged Presence row holds the book [bookHash] — i.e. can serve
/// it, and has it ready to read.
bool presenceHoldsBook(Map<String, dynamic> user, String bookHash) {
  final hashes = user['ready_book_hashes'];
  return hashes is List && hashes.contains(bookHash);
}

/// How a room member's app relates to this one's wire protocol.
enum ProtocolCompatibility {
  /// At least one of their connections speaks this app's protocol.
  compatible,

  /// Their app is older: they need to update it to read along.
  older,

  /// Their app is newer: this app needs an update.
  newer,
}

/// The wire protocol of one raw Presence meta. Apps from before the field
/// existed send nothing and count as 0.
int presenceProtocol(Map<String, dynamic> meta) {
  final protocol = meta['protocol'];
  return protocol is num ? protocol.toInt() : 0;
}

/// Whether the member in [user] — a merged row from [mergePresenceUsers] — can
/// read in the same room as an app speaking [localProtocol].
///
/// A member with any connection on [localProtocol] is compatible: that device
/// takes part, and a lingering meta from before an app update does not count
/// against them. Otherwise any newer connection means this app is the one
/// behind.
ProtocolCompatibility presenceProtocolCompatibility(
  Map<String, dynamic> user, {
  int localProtocol = AppConstants.roomProtocolVersion,
}) {
  final listed = user['protocols'];
  final protocols = listed is List
      ? listed.whereType<num>().map((protocol) => protocol.toInt()).toList()
      : <int>[];
  if (protocols.isEmpty) protocols.add(presenceProtocol(user));
  if (protocols.contains(localProtocol)) {
    return ProtocolCompatibility.compatible;
  }
  if (protocols.any((protocol) => protocol > localProtocol)) {
    return ProtocolCompatibility.newer;
  }
  return ProtocolCompatibility.older;
}

DateTime presenceTime(Map<String, dynamic> presence) {
  return DateTime.tryParse(presence['online_at'] as String? ?? '') ??
      DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
}
