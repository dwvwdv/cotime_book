import 'package:flutter/material.dart';
import '../config/theme.dart';
import '../models/recent_room.dart';
import 'paper.dart';
import '../l10n/l10n.dart';

/// Rooms this device has been in, newest first. Tapping one goes back in.
class RecentRoomsList extends StatelessWidget {
  final List<RecentRoom> rooms;
  final bool enabled;
  final ValueChanged<RecentRoom> onOpen;
  final ValueChanged<RecentRoom> onForget;
  final DateTime Function() now;

  const RecentRoomsList({
    super.key,
    required this.rooms,
    required this.onOpen,
    required this.onForget,
    this.enabled = true,
    this.now = DateTime.now,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionHeader(label: context.l10n.recentRooms),
        for (final room in rooms) _row(context.l10n, room),
      ],
    );
  }

  Widget _row(AppLocalizations l10n, RecentRoom room) {
    return Container(
      decoration: const BoxDecoration(border: Border(bottom: AppTheme.rule)),
      child: Row(
        children: [
          Expanded(
            child: InkWell(
              onTap: enabled ? () => onOpen(room) : null,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      room.code,
                      style: const TextStyle(
                        fontFamily: AppTheme.serif,
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 4,
                        color: AppTheme.ink,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      l10n.recentRoomSubtitle(
                        room.bookTitle ?? l10n.noBookYet,
                        describeVisit(room.lastVisitedAt, now(), l10n: l10n),
                      ),
                      style: AppTheme.caption,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ),
          ),
          IconButton(
            tooltip: l10n.removeFromRecentRooms(room.code),
            onPressed: enabled ? () => onForget(room) : null,
            icon: const Icon(Icons.close, size: 20),
          ),
        ],
      ),
    );
  }
}

/// A visit date in words. Calendar days, not 24-hour spans: last night is
/// "Yesterday" even when it was only a few hours ago.
String describeVisit(
  DateTime visitedAt,
  DateTime now, {
  AppLocalizations? l10n,
}) {
  final strings = l10n ?? appStrings;
  final visit = visitedAt.toLocal();
  final local = now.toLocal();
  // Compared as UTC dates so a daylight-saving change can't make a day 23h.
  final days = DateTime.utc(local.year, local.month, local.day)
      .difference(DateTime.utc(visit.year, visit.month, visit.day))
      .inDays;
  if (days <= 0) return strings.today;
  if (days == 1) return strings.yesterday;
  if (days < 7) return strings.daysAgo(days);
  String two(int n) => n.toString().padLeft(2, '0');
  return '${visit.year}-${two(visit.month)}-${two(visit.day)}';
}
