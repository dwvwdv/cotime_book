import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../config/theme.dart';
import '../providers/presence_provider.dart';
import '../services/presence_merge.dart';

/// Who is in the room while reading, and who has stepped back to the lobby.
///
/// Watches Presence rather than taking a snapshot: the sheet stays open while
/// people come and go, and a list frozen at open time showed members who had
/// already left and missed the ones who had just arrived.
class ReaderMembersSheet extends ConsumerWidget {
  const ReaderMembersSheet({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final presenceState = ref.watch(presenceProvider);
    final users = presenceState.onlineUsers;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          presenceState.isReconnecting
              ? 'Reconnecting to the room...'
              : '${presenceState.onlineCount} Members Online',
          style: AppTheme.title,
        ),
        const SizedBox(height: 12),
        const Divider(),
        Flexible(
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final user in users)
                _MemberRow(
                  nickname: user['nickname'] as String? ?? 'Unknown',
                  isReading: user['is_reading'] as bool? ?? false,
                  version: presenceProtocolCompatibility(user),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _MemberRow extends StatelessWidget {
  final String nickname;
  final bool isReading;
  final ProtocolCompatibility version;

  const _MemberRow({
    required this.nickname,
    required this.isReading,
    required this.version,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          // Solid = reading, hollow = stepped out. Previously green vs amber,
          // which is the same gray on an e-ink panel.
          Container(
            width: 14,
            height: 14,
            decoration: BoxDecoration(
              color: isReading ? AppTheme.ink : AppTheme.paper,
              shape: BoxShape.circle,
              border: Border.all(color: AppTheme.ink, width: 2),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Text(
              nickname,
              style: TextStyle(
                fontSize: 17,
                fontWeight: isReading ? FontWeight.w700 : FontWeight.w400,
                color: AppTheme.ink,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                isReading ? 'Reading' : 'Left the reader',
                style: AppTheme.caption,
              ),
              // Their page turns and this reader's never reach each other, so
              // waiting on them is waiting forever (GH-33). Bold, not a colour.
              if (version != ProtocolCompatibility.compatible)
                Text(
                  version == ProtocolCompatibility.older
                      ? 'Needs app update'
                      : 'Newer app — update yours',
                  style: AppTheme.caption.copyWith(
                    fontWeight: FontWeight.w700,
                    color: AppTheme.ink,
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
