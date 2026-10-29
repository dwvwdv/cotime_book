import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/member_removal.dart';
import 'auth_provider.dart';
import 'presence_provider.dart';
import 'room_provider.dart';

final memberRemovalProvider =
    StateNotifierProvider<MemberRemovalNotifier, List<MemberRemovalProposal>>((
      ref,
    ) {
      final realtime = ref.read(realtimeServiceProvider);
      final notifier = MemberRemovalNotifier(
        proposals: realtime.broadcastStream(MemberRemovalProposal.event),
        memberships: realtime.broadcastStream('membership_changed'),
        send: (event, payload) =>
            realtime.broadcast(event: event, payload: payload),
        vote: (userId) =>
            ref.read(roomProvider.notifier).voteToRemoveMember(userId),
        onRemoved: () =>
            ref.read(roomProvider.notifier).confirmMembershipAfterRemoval(),
        whoAmI: () {
          final userId = ref.read(authProvider).userId;
          final room = ref.read(roomProvider);
          final nickname = room.members
              .where((member) => member.userId == userId)
              .map((member) => member.nickname)
              .firstOrNull;
          return (
            userId: userId,
            nickname: nickname ?? ref.read(authProvider).nickname,
            roomCode: room.currentRoom?.code,
          );
        },
      );
      // A vote belongs to the room it was asked in.
      ref.listen(
        roomProvider.select((state) => state.currentRoom?.id),
        (_, _) => notifier.reset(),
      );
      return notifier;
    });

typedef MemberRemovalIdentity = ({
  String? userId,
  String nickname,
  String? roomCode,
});

/// Voting someone out of the room, and the votes this reader is asked to
/// join.
///
/// The state is the open votes waiting for this reader's answer, oldest
/// first. The database counts the votes; what travels over Broadcast here is
/// only who to ask and who is out, and losing it costs a prompt (anyone can
/// still vote from the member list) or the reconnect grace (page sync falls
/// back to waiting it out).
class MemberRemovalNotifier extends StateNotifier<List<MemberRemovalProposal>> {
  /// The database's vote window (`vote_remove_member`): a prompt for a vote
  /// that has run out would ask for a vote that starts over.
  static const defaultProposalLifetime = Duration(minutes: 5);

  final Future<void> Function(String event, Map<String, dynamic> payload) _send;
  final Future<MemberRemovalVote?> Function(String targetUserId) _vote;
  final Future<void> Function() _onRemoved;
  final MemberRemovalIdentity Function() _whoAmI;
  final Duration _proposalLifetime;
  final List<StreamSubscription<Map<String, dynamic>>> _subscriptions = [];

  /// Targets this reader voted on or waved off: target → until when. A second
  /// voter's proposal for the same target does not ask again.
  final Map<String, DateTime> _answered = {};
  final Map<String, Timer> _expiry = {};

  MemberRemovalNotifier({
    required Stream<Map<String, dynamic>> proposals,
    required Stream<Map<String, dynamic>> memberships,
    required Future<void> Function(String event, Map<String, dynamic> payload)
    send,
    required Future<MemberRemovalVote?> Function(String targetUserId) vote,
    required Future<void> Function() onRemoved,
    required MemberRemovalIdentity Function() whoAmI,
    Duration proposalLifetime = defaultProposalLifetime,
  }) : _send = send,
       _vote = vote,
       _onRemoved = onRemoved,
       _whoAmI = whoAmI,
       _proposalLifetime = proposalLifetime,
       super(const []) {
    _subscriptions.addAll([
      proposals.listen(_onProposal),
      memberships.listen(_onMembership),
    ]);
  }

  /// Votes [targetUserId] out and tells the room. Null when this device is
  /// not in the room any more; errors from the vote itself are thrown.
  Future<MemberRemovalVote?> askToLeave({
    required String targetUserId,
    required String targetNickname,
  }) async {
    final result = await _vote(targetUserId);
    if (result == null || !mounted) return result;
    _answer(targetUserId);
    final me = _whoAmI();
    final userId = me.userId;
    final roomCode = me.roomCode;
    if (userId == null || roomCode == null) return result;
    switch (result.status) {
      case MemberRemovalStatus.removed:
        // The removed member's own device, if it is still on, leaves on this;
        // everyone else stops waiting for it.
        await _sendQuietly('membership_changed', {
          'action': 'removed',
          'room_code': roomCode,
          'user_id': targetUserId,
        });
      case MemberRemovalStatus.voting:
        await _sendQuietly(
          MemberRemovalProposal.event,
          MemberRemovalProposal(
            roomCode: roomCode,
            targetUserId: targetUserId,
            targetNickname: targetNickname,
            voterUserId: userId,
            voterNickname: me.nickname,
            votes: result.votes,
            needed: result.needed,
          ).toWire(),
        );
      case MemberRemovalStatus.gone:
        _drop(targetUserId);
    }
    return result;
  }

  /// "Not now": stop asking about [targetUserId] for this vote.
  void dismiss(String targetUserId) {
    _answer(targetUserId);
  }

  /// A new room, or none: nothing asked in the last one applies.
  void reset() {
    for (final timer in _expiry.values) {
      timer.cancel();
    }
    _expiry.clear();
    _answered.clear();
    if (state.isNotEmpty) state = const [];
  }

  void _onProposal(Map<String, dynamic> payload) {
    final proposal = MemberRemovalProposal.fromWire(payload);
    if (proposal == null || !mounted) return;
    final me = _whoAmI();
    final target = proposal.targetUserId;
    if (me.userId == null ||
        proposal.roomCode != me.roomCode ||
        // Being asked whether to remove yourself would be a strange prompt.
        target == me.userId ||
        // Our own vote, echoed back.
        proposal.voterUserId == me.userId ||
        _isAnswered(target)) {
      return;
    }
    state = [
      for (final open in state)
        if (open.targetUserId != target) open,
      proposal,
    ];
    _expiry[target]?.cancel();
    _expiry[target] = Timer(_proposalLifetime, () => _drop(target));
  }

  void _onMembership(Map<String, dynamic> payload) {
    final userId = payload['user_id'];
    final action = payload['action'];
    if (userId is! String || !mounted) return;
    if (action != 'removed' && action != 'leaving') return;
    _drop(userId);
    _answered.remove(userId);
    if (action == 'removed' && userId == _whoAmI().userId) {
      unawaited(_onRemoved());
    }
  }

  void _answer(String targetUserId) {
    _answered[targetUserId] = DateTime.now().add(_proposalLifetime);
    _drop(targetUserId);
  }

  bool _isAnswered(String targetUserId) {
    final until = _answered[targetUserId];
    if (until == null) return false;
    if (DateTime.now().isBefore(until)) return true;
    _answered.remove(targetUserId);
    return false;
  }

  void _drop(String targetUserId) {
    _expiry.remove(targetUserId)?.cancel();
    if (!mounted) return;
    if (state.any((open) => open.targetUserId == targetUserId)) {
      state = [
        for (final open in state)
          if (open.targetUserId != targetUserId) open,
      ];
    }
  }

  Future<void> _sendQuietly(String event, Map<String, dynamic> payload) async {
    try {
      await _send(event, payload);
    } catch (_) {
      // The vote is in the database either way; the roster catches up on
      // its next read, and the others can vote from the member list.
    }
  }

  @override
  void dispose() {
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    for (final timer in _expiry.values) {
      timer.cancel();
    }
    super.dispose();
  }
}
