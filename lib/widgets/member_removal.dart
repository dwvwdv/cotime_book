import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/theme.dart';
import '../models/member_removal.dart';
import '../providers/member_removal_provider.dart';
import 'paper.dart';

/// The button on a member's row that starts a vote to remove them.
class AskToLeaveButton extends StatelessWidget {
  final String nickname;
  final VoidCallback onPressed;

  const AskToLeaveButton({
    super.key,
    required this.nickname,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: 'Ask $nickname to leave',
      iconSize: 24,
      style: IconButton.styleFrom(minimumSize: const Size.square(48)),
      icon: const Icon(Icons.person_remove_outlined, color: AppTheme.ink),
      onPressed: onPressed,
    );
  }
}

/// Asks this reader to confirm, then votes [nickname] out of the room and
/// says how it went.
Future<void> askMemberToLeave(
  BuildContext context,
  WidgetRef ref, {
  required String userId,
  required String nickname,
}) async {
  final confirmed = await showPaperDialog<bool>(
    context: context,
    builder: (dialogContext) => _RemovalQuestion(
      title: 'Ask $nickname to leave?',
      message:
          '$nickname will be taken out of the room, and nobody waits for '
          'them to turn the page. They can join again with the room code.'
          '\n\nIf others are here too, more than half of you have to agree.',
      confirmLabel: 'Ask to leave',
      onConfirm: () => Navigator.of(dialogContext).pop(true),
      onCancel: () => Navigator.of(dialogContext).pop(false),
    ),
  );
  if (confirmed != true || !context.mounted) return;
  await _vote(
    ScaffoldMessenger.maybeOf(context),
    ref.read(memberRemovalProvider.notifier),
    userId: userId,
    nickname: nickname,
  );
}

/// Opens a prompt for each vote this reader is newly asked to join. Call
/// from the build method of a room screen.
void listenForMemberRemovalVotes(BuildContext context, WidgetRef ref) {
  ref.listen<List<MemberRemovalProposal>>(memberRemovalProvider, (
    previous,
    next,
  ) {
    final seen = {for (final open in previous ?? const []) open.targetUserId};
    final notifier = ref.read(memberRemovalProvider.notifier);
    for (final proposal in next) {
      final target = proposal.targetUserId;
      if (seen.contains(target)) continue;
      unawaited(
        showPaperDialog<bool>(
          context: context,
          builder: (_) => MemberRemovalPrompt(proposal: proposal),
        ).then((agreed) {
          // Closed from the corner, by a tap outside or by Back: as good as
          // "Not now", or the next voter's proposal asks again.
          if (agreed != true && notifier.mounted) notifier.dismiss(target);
        }),
      );
    }
  });
}

/// Someone else voted to remove a member and this reader is asked to agree.
///
/// Watches the open votes: a later voter's count replaces the one it opened
/// with, and once this vote is decided or runs out, the prompt says so
/// instead of offering a vote that would start over. Pops with true when
/// this reader agreed.
class MemberRemovalPrompt extends ConsumerWidget {
  /// The vote it opened for; only its target is kept to.
  final MemberRemovalProposal proposal;

  const MemberRemovalPrompt({super.key, required this.proposal});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final latest = ref.watch(
      memberRemovalProvider.select(
        (votes) => votes
            .where((vote) => vote.targetUserId == proposal.targetUserId)
            .firstOrNull,
      ),
    );
    final target = proposal.targetNickname;
    if (latest == null) {
      return _RemovalQuestion(
        title: 'Remove $target?',
        message: 'This vote is over.',
        onCancel: () => Navigator.of(context).pop(),
        cancelLabel: 'Close',
      );
    }
    final remaining = latest.remaining;
    return _RemovalQuestion(
      title: 'Remove $target?',
      message:
          '${latest.voterNickname} asked $target to leave the room, so '
          'nobody waits for them to turn the page. $target can join again '
          'with the room code.'
          '${remaining > 0 ? '\n\n${MemberRemovalVote.moreVotes(remaining)} needed.' : ''}',
      confirmLabel: 'Agree',
      cancelLabel: 'Not now',
      onConfirm: () {
        // Read before the pop: this prompt's context is gone after it.
        final messenger = ScaffoldMessenger.maybeOf(context);
        final notifier = ref.read(memberRemovalProvider.notifier);
        Navigator.of(context).pop(true);
        unawaited(
          _vote(
            messenger,
            notifier,
            userId: proposal.targetUserId,
            nickname: target,
          ),
        );
      },
      // The listener that opened this dismisses the vote however it closes.
      onCancel: () => Navigator.of(context).pop(false),
    );
  }
}

Future<void> _vote(
  ScaffoldMessengerState? messenger,
  MemberRemovalNotifier notifier, {
  required String userId,
  required String nickname,
}) async {
  String? message;
  try {
    final result = await notifier.askToLeave(
      targetUserId: userId,
      targetNickname: nickname,
    );
    if (result != null) message = describeRemovalVote(result, nickname);
  } catch (_) {
    message = 'Could not ask $nickname to leave. Try again.';
  }
  if (message == null || messenger == null) return;
  showPaperMessageOn(messenger, message, duration: const Duration(seconds: 6));
}

/// What a vote did, for the reader who cast it.
String describeRemovalVote(MemberRemovalVote vote, String nickname) {
  return switch (vote.status) {
    MemberRemovalStatus.removed => '$nickname was removed from the room.',
    MemberRemovalStatus.gone => '$nickname is no longer in the room.',
    MemberRemovalStatus.voting =>
      'Your vote is in. ${MemberRemovalVote.moreVotes(vote.remaining)} '
          'needed to remove $nickname.',
  };
}

class _RemovalQuestion extends StatelessWidget {
  final String title;
  final String message;
  final String? confirmLabel;
  final String cancelLabel;
  final VoidCallback? onConfirm;
  final VoidCallback onCancel;

  const _RemovalQuestion({
    required this.title,
    required this.message,
    required this.onCancel,
    this.confirmLabel,
    this.onConfirm,
    this.cancelLabel = 'Cancel',
  });

  @override
  Widget build(BuildContext context) {
    final confirmLabel = this.confirmLabel;
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(title, style: AppTheme.title),
          const SizedBox(height: 16),
          Text(message, style: AppTheme.body),
          const SizedBox(height: 24),
          if (confirmLabel != null && onConfirm != null) ...[
            FilledButton(onPressed: onConfirm, child: Text(confirmLabel)),
            const SizedBox(height: 12),
          ],
          OutlinedButton(onPressed: onCancel, child: Text(cancelLabel)),
        ],
      ),
    );
  }
}
