import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../config/theme.dart';
import '../providers/auth_provider.dart';
import '../providers/presence_provider.dart';
import '../providers/room_provider.dart';
import '../services/presence_merge.dart';
import 'member_removal.dart';
import '../l10n/l10n.dart';

/// Who is in the room while reading, and who has stepped back to the lobby.
///
/// Watches Presence rather than taking a snapshot: the sheet stays open while
/// people come and go, and a list frozen at open time showed members who had
/// already left and missed the ones who had just arrived.
///
/// Members who are in the room but not connected — the reader the bar says
/// it is waiting for, among them — come from the database roster, since they
/// are by definition not in Presence. Any other member can be voted out from
/// here.
class ReaderMembersSheet extends ConsumerStatefulWidget {
  /// Starts a vote to remove a member: user id, nickname. No buttons when
  /// null.
  final void Function(String userId, String nickname)? onAskToLeave;

  const ReaderMembersSheet({super.key, this.onAskToLeave});

  @override
  ConsumerState<ReaderMembersSheet> createState() => _ReaderMembersSheetState();
}

class _ReaderMembersSheetState extends ConsumerState<ReaderMembersSheet> {
  StreamSubscription<Map<String, dynamic>>? _membershipChanges;

  @override
  void initState() {
    super.initState();
    // The reader does not keep the roster fresh the way the lobby does, and
    // this is where someone looks for who is holding the room up. While the
    // sheet is open, someone voted out (or arriving) changes it too.
    Future<void>.microtask(() {
      if (!mounted) return;
      final rooms = ref.read(roomProvider.notifier);
      unawaited(rooms.refreshMembers());
      _membershipChanges = ref
          .read(realtimeServiceProvider)
          .broadcastStream('membership_changed')
          .listen((_) => unawaited(rooms.refreshMembers()));
    });
  }

  @override
  void dispose() {
    unawaited(_membershipChanges?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final presenceState = ref.watch(presenceProvider);
    final users = presenceState.onlineUsers;
    final members = ref.watch(roomProvider.select((state) => state.members));
    final currentUserId = ref.watch(authProvider.select((auth) => auth.userId));
    final onlineIds = {for (final user in users) user['user_id']};
    // Off the channel, Presence is empty or stale and everyone would read as
    // not connected — inviting a vote against someone who is reading.
    final connected = presenceState.isConnected;
    final notConnected = [
      if (connected)
        for (final member in members)
          if (!onlineIds.contains(member.userId) &&
              member.userId != currentUserId)
            member,
    ];
    final onAskToLeave = connected ? widget.onAskToLeave : null;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          presenceState.isReconnecting
              ? context.l10n.reconnectingToRoom
              : context.l10n.membersOnline(presenceState.onlineCount),
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
                  nickname:
                      user['nickname'] as String? ?? context.l10n.unknownMember,
                  status: user['is_reading'] == true
                      ? _MemberStatus.reading
                      : _MemberStatus.outOfReader,
                  version: presenceProtocolCompatibility(user),
                  onAskToLeave:
                      onAskToLeave == null ||
                          user['user_id'] is! String ||
                          user['user_id'] == currentUserId
                      ? null
                      : () => onAskToLeave(
                          user['user_id'] as String,
                          user['nickname'] as String? ??
                              context.l10n.unknownMember,
                        ),
                ),
              for (final member in notConnected)
                _MemberRow(
                  nickname: member.nickname,
                  status: _MemberStatus.notConnected,
                  version: ProtocolCompatibility.compatible,
                  onAskToLeave: onAskToLeave == null
                      ? null
                      : () => onAskToLeave(member.userId, member.nickname),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

enum _MemberStatus { reading, outOfReader, notConnected }

class _MemberRow extends StatelessWidget {
  final String nickname;
  final _MemberStatus status;
  final ProtocolCompatibility version;
  final VoidCallback? onAskToLeave;

  const _MemberRow({
    required this.nickname,
    required this.status,
    required this.version,
    this.onAskToLeave,
  });

  @override
  Widget build(BuildContext context) {
    final isReading = status == _MemberStatus.reading;
    final onAskToLeave = this.onAskToLeave;
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
              Text(switch (status) {
                _MemberStatus.reading => context.l10n.statusReading,
                _MemberStatus.outOfReader => context.l10n.statusLeftReader,
                _MemberStatus.notConnected => context.l10n.statusNotConnected,
              }, style: AppTheme.caption),
              // Their page turns and this reader's never reach each other, so
              // waiting on them is waiting forever (GH-33). Bold, not a colour.
              if (version != ProtocolCompatibility.compatible)
                Text(
                  version == ProtocolCompatibility.older
                      ? context.l10n.needsAppUpdate
                      : context.l10n.newerAppUpdateYours,
                  style: AppTheme.caption.copyWith(
                    fontWeight: FontWeight.w700,
                    color: AppTheme.ink,
                  ),
                ),
            ],
          ),
          if (onAskToLeave != null) ...[
            const SizedBox(width: 4),
            AskToLeaveButton(nickname: nickname, onPressed: onAskToLeave),
          ],
        ],
      ),
    );
  }
}
