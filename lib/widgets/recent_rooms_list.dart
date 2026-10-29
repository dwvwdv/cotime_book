import 'package:flutter/material.dart';
import '../config/theme.dart';
import '../models/recent_room.dart';
import 'paper.dart';

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
        const SectionHeader(label: 'Recent rooms'),
        for (final room in rooms) _row(room),
      ],
    );
  }

  Widget _row(RecentRoom room) {
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
                      '${room.bookTitle ?? 'No book yet'} · '
                      '${describeVisit(room.lastVisitedAt, now())}',
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
            tooltip: 'Remove ${room.code} from recent rooms',
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
String describeVisit(DateTime visitedAt, DateTime now) {
  final visit = visitedAt.toLocal();
  final local = now.toLocal();
  // Compared as UTC dates so a daylight-saving change can't make a day 23h.
  final days = DateTime.utc(local.year, local.month, local.day)
      .difference(DateTime.utc(visit.year, visit.month, visit.day))
      .inDays;
  if (days <= 0) return 'Today';
  if (days == 1) return 'Yesterday';
  if (days < 7) return '$days days ago';
  String two(int n) => n.toString().padLeft(2, '0');
  return '${visit.year}-${two(visit.month)}-${two(visit.day)}';
}
