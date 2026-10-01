import 'package:flutter/material.dart';
import '../config/theme.dart';
import '../models/room_member.dart';
import 'user_avatar.dart';

class MemberList extends StatelessWidget {
  final List<RoomMember> members;
  final String? currentUserId;

  const MemberList({
    super.key,
    required this.members,
    this.currentUserId,
  });

  @override
  Widget build(BuildContext context) {
    if (members.isEmpty) {
      return const Center(
        child: Text('No members yet', style: AppTheme.caption),
      );
    }

    // The list fills an Expanded slot, so it must scroll on its own: a
    // shrink-wrapped, unscrollable list silently clipped members past the fold.
    return ListView.separated(
      itemCount: members.length,
      separatorBuilder: (_, _) =>
          const Divider(height: 1, thickness: 1, color: AppTheme.inkFaint),
      itemBuilder: (context, index) {
        final member = members[index];
        final isMe = member.userId == currentUserId;

        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Row(
            children: [
              UserAvatar(
                nickname: member.nickname,
                isOnline: member.isOnline,
              ),
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
                      member.isOnline ? 'Online' : 'Offline',
                      style: AppTheme.caption,
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
