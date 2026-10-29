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
    for (final proposal in next) {
      if (seen.contains(proposal.targetUserId)) continue;
      unawaited(
        showPaperDialog<void>(
          context: context,
          builder: (_) => MemberRemovalPrompt(proposal: proposal),
        ),
      );
    }
  });
}

/// Someone else voted to remove a member and this reader is asked to agree.
///
/// Watches the open votes: once this one is decided or runs out, the prompt
/// says so instead of offering a vote that would start over.
class MemberRemovalPrompt extends ConsumerWidget {
  final MemberRemovalProposal proposal;

  const MemberRemovalPrompt({super.key, required this.proposal});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final open = ref.watch(
      memberRemovalProvider.select(
        (votes) =>
            votes.any((vote) => vote.targetUserId == proposal.targetUserId),
      ),
    );
    final target = proposal.targetNickname;
    if (!open) {
      return _RemovalQuestion(
        title: 'Remove $target?',
        message: 'This vote is over.',
        onCancel: () => Navigator.of(context).pop(),
        cancelLabel: 'Close',
      );
    }
    final remaining = proposal.needed - proposal.votes;
    return _RemovalQuestion(
      title: 'Remove $target?',
      message:
          '${proposal.voterNickname} asked $target to leave the room, so '
          'nobody waits for them to turn the page. $target can join again '
          'with the room code.'
          '${remaining > 0 ? '\n\n$remaining more ${remaining == 1 ? 'vote' : 'votes'} needed.' : ''}',
      confirmLabel: 'Agree',
      cancelLabel: 'Not now',
      onConfirm: () {
        // Read before the pop: this prompt's context is gone after it.
        final messenger = ScaffoldMessenger.maybeOf(context);
        final notifier = ref.read(memberRemovalProvider.notifier);
        Navigator.of(context).pop();
        unawaited(
          _vote(
            messenger,
            notifier,
            userId: proposal.targetUserId,
            nickname: target,
          ),
        );
      },
      onCancel: () {
        ref.read(memberRemovalProvider.notifier).dismiss(proposal.targetUserId);
        Navigator.of(context).pop();
      },
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
  messenger.showSnackBar(
    SnackBar(content: Text(message), duration: const Duration(seconds: 6)),
    snackBarAnimationStyle: AnimationStyle.noAnimation,
  );
}

/// What a vote did, for the reader who cast it.
String describeRemovalVote(MemberRemovalVote vote, String nickname) {
  return switch (vote.status) {
    MemberRemovalStatus.removed => '$nickname was removed from the room.',
    MemberRemovalStatus.gone => '$nickname is no longer in the room.',
    MemberRemovalStatus.voting =>
      'Your vote is in. ${vote.remaining} more '
          '${vote.remaining == 1 ? 'vote' : 'votes'} needed to remove '
          '$nickname.',
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
