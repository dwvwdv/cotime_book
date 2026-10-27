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
    // Per connection like the hashes above: the device that holds the book
    // has to be the one that can send it directly.
    latest['direct_book_hashes'] = metas
        .where(
          (meta) => meta['has_book'] == true && meta['direct_transfer'] == true,
        )
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
    // Every connection's protocol range, not the latest one: a person can
    // follow the room on any device that understands it, and an expired meta
    // from before an app update must not make them look out of date. See
    // [presenceProtocolCompatibility].
    latest.remove('protocol');
    latest.remove('protocol_min');
    latest['protocols'] =
        metas
            .map(presenceProtocolRange)
            .toSet()
            .map((range) => [range.version, range.oldestCompatible])
            .toList()
          ..sort((a, b) => a[0] != b[0] ? a[0] - b[0] : a[1] - b[1]);
    // The versions of the connections that are in the book and can be asked
    // to agree: a request only a newer version answers is answered by one of
    // these or by nobody, whatever the person's other devices speak.
    latest['reader_protocols'] =
        metas
            .where(
              (meta) =>
                  meta['is_reading'] == true && meta['reader_ready'] == true,
            )
            .map((meta) => presenceProtocolRange(meta).version)
            .toSet()
            .toList()
          ..sort();
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

/// Whether a merged Presence row has [bookHash] on a device that can send it
/// over a direct connection (GH-60). Apps from before it never say so and
/// are only asked over Realtime.
bool presenceSendsBookDirectly(Map<String, dynamic> user, String bookHash) {
  final hashes = user['direct_book_hashes'];
  return hashes is List && hashes.contains(bookHash);
}

/// How a room member's app relates to this one's wire protocol.
enum ProtocolCompatibility {
  /// At least one of their connections reads together with this app.
  compatible,

  /// Their app is older than this one supports: they need to update it.
  older,

  /// Their app no longer supports this one: this app needs an update.
  newer,
}

/// What one Presence connection speaks: its protocol [version], and the
/// oldest version it still reads together with.
class ProtocolRange {
  const ProtocolRange(this.version, this.oldestCompatible);

  final int version;
  final int oldestCompatible;

  @override
  bool operator ==(Object other) =>
      other is ProtocolRange &&
      other.version == version &&
      other.oldestCompatible == oldestCompatible;

  @override
  int get hashCode => Object.hash(version, oldestCompatible);
}

/// The protocol range of one raw Presence meta. Apps from before the fields
/// existed send nothing and count as version 0 with no older versions.
ProtocolRange presenceProtocolRange(Map<String, dynamic> meta) {
  final version = meta['protocol'];
  final oldest = meta['protocol_min'];
  final v = version is num ? version.toInt() : 0;
  return ProtocolRange(v, oldest is num ? oldest.toInt() : v);
}

/// Whether the member in [user] — a merged row from [mergePresenceUsers] — can
/// read in the same room as an app speaking [localProtocol] that still
/// supports versions back to [localOldestCompatible].
///
/// Two connections read together when each one's version is at least the
/// other's oldest supported version. A member with any such connection is
/// compatible: that device takes part, and a lingering meta from before an
/// app update does not count against them. Otherwise any connection that has
/// moved past this app's version means this app is the one behind.
ProtocolCompatibility presenceProtocolCompatibility(
  Map<String, dynamic> user, {
  int localProtocol = AppConstants.roomProtocolVersion,
  int localOldestCompatible = AppConstants.minCompatibleRoomProtocol,
}) {
  final listed = user['protocols'];
  final ranges = <ProtocolRange>[
    if (listed is List)
      for (final entry in listed)
        if (entry is List &&
            entry.length == 2 &&
            entry[0] is num &&
            entry[1] is num)
          ProtocolRange((entry[0] as num).toInt(), (entry[1] as num).toInt()),
  ];
  if (ranges.isEmpty) ranges.add(presenceProtocolRange(user));
  if (ranges.any(
    (range) =>
        range.version >= localOldestCompatible &&
        range.oldestCompatible <= localProtocol,
  )) {
    return ProtocolCompatibility.compatible;
  }
  if (ranges.any((range) => range.oldestCompatible > localProtocol)) {
    return ProtocolCompatibility.newer;
  }
  return ProtocolCompatibility.older;
}

/// Whether some connection of [user] (a merged row, or one raw meta) that
/// would be asked to agree speaks [version] or later. A request only that
/// version answers is put to them. A newer app open in the lobby does not
/// count: it is not asked, and the old one in the book drops the request.
bool presenceSpeaksProtocol(Map<String, dynamic> user, int version) {
  final reading = user['reader_protocols'];
  if (reading is List && reading.isNotEmpty) {
    return reading.any((entry) => entry is num && entry >= version);
  }
  final listed = user['protocols'];
  if (listed is List && listed.isNotEmpty) {
    return listed.any(
      (entry) =>
          entry is List &&
          entry.isNotEmpty &&
          entry[0] is num &&
          (entry[0] as num) >= version,
    );
  }
  return presenceProtocolRange(user).version >= version;
}

DateTime presenceTime(Map<String, dynamic> presence) {
  return DateTime.tryParse(presence['online_at'] as String? ?? '') ??
      DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
}
