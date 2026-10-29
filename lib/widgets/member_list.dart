import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import '../config/theme.dart';
import '../models/room_member.dart';
import '../services/presence_merge.dart';
import 'user_avatar.dart';

class MemberList extends StatelessWidget {
  final List<RoomMember> members;
  final String? currentUserId;

  /// Online members' app versions relative to this one, by user ID (GH-33).
  final Map<String, ProtocolCompatibility> appVersions;

  /// Lists every member at full height, for a page that scrolls as a whole
  /// (GH-45). Otherwise the list fills the space it is given and scrolls on
  /// its own.
  final bool shrinkWrap;

  const MemberList({
    super.key,
    required this.members,
    this.currentUserId,
    this.appVersions = const {},
    this.shrinkWrap = false,
  });

  /// Online first, each group in join order. A member whose app was killed
  /// stays in the room until the server evicts them; at the top of the list
  /// they read as still here.
  static List<RoomMember> ordered(List<RoomMember> members) {
    final sorted = [...members];
    mergeSort<RoomMember>(
      sorted,
      compare: (a, b) => (b.isOnline ? 1 : 0) - (a.isOnline ? 1 : 0),
    );
    return sorted;
  }

  @override
  Widget build(BuildContext context) {
    final members = ordered(this.members);
    if (members.isEmpty) {
      const empty = Text('No members yet', style: AppTheme.caption);
      return shrinkWrap
          ? const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Center(child: empty),
            )
          : const Center(child: empty);
    }

    // In an Expanded slot the list must scroll on its own: a shrink-wrapped,
    // unscrollable list there silently clipped members past the fold. Only
    // inside a page that itself scrolls may it give up scrolling.
    return ListView.separated(
      shrinkWrap: shrinkWrap,
      physics: shrinkWrap ? const NeverScrollableScrollPhysics() : null,
      itemCount: members.length,
      separatorBuilder: (_, _) =>
          const Divider(height: 1, thickness: 1, color: AppTheme.inkFaint),
      itemBuilder: (context, index) {
        final member = members[index];
        final isMe = member.userId == currentUserId;
        final version = member.isOnline ? appVersions[member.userId] : null;
        final versionLabel = switch (version) {
          ProtocolCompatibility.older => 'Needs app update',
          ProtocolCompatibility.newer => 'Newer app — update yours',
          _ => null,
        };

        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Row(
            children: [
              UserAvatar(nickname: member.nickname, isOnline: member.isOnline),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text.rich(
                      TextSpan(
                        text: member.nickname,
                        children: [
                          if (isMe)
                            const TextSpan(
                              text: '  (You)',
                              style: TextStyle(
                                fontWeight: FontWeight.w400,
                                color: AppTheme.inkMuted,
                                fontSize: 14,
                              ),
                            ),
                        ],
                      ),
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 17,
                        color: AppTheme.ink,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      member.isOnline ? 'Online' : 'Away — not connected',
                      style: AppTheme.caption,
                    ),
                    // Bold ink, not a colour: on e-ink red is just gray.
                    if (versionLabel != null)
                      Text(
                        versionLabel,
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: AppTheme.ink,
                        ),
                      ),
                  ],
                ),
              ),
              // Spelled out: a filled-vs-outlined book glyph was the only
              // signal before, and it relied on green to be noticed.
              _BookTag(hasBook: member.hasBook),
            ],
          ),
        );
      },
    );
  }
}

class _BookTag extends StatelessWidget {
  final bool hasBook;

  const _BookTag({required this.hasBook});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: hasBook ? AppTheme.ink : AppTheme.paper,
        border: Border.all(
          color: hasBook ? AppTheme.ink : AppTheme.inkFaint,
          width: AppTheme.ruleWidth,
        ),
        borderRadius: BorderRadius.circular(AppTheme.radius),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            hasBook ? Icons.book : Icons.book_outlined,
            size: 16,
            color: hasBook ? AppTheme.paper : AppTheme.inkMuted,
          ),
          const SizedBox(width: 4),
          Text(
            hasBook ? 'Has book' : 'No book',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: hasBook ? AppTheme.paper : AppTheme.inkMuted,
            ),
          ),
        ],
      ),
    );
  }
}
