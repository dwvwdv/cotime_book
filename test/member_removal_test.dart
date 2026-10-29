import 'dart:async';

import 'package:cotime_book/models/member_removal.dart';
import 'package:cotime_book/providers/member_removal_provider.dart';
import 'package:cotime_book/widgets/member_removal.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('MemberRemovalVote', () {
    test('reads the vote result', () {
      final vote = MemberRemovalVote.fromJson({
        'status': 'voting',
        'votes': 1,
        'needed': 3,
      });
      expect(vote.status, MemberRemovalStatus.voting);
      expect(vote.remaining, 2);
      expect(
        MemberRemovalVote.fromJson({'status': 'removed'}).status,
        MemberRemovalStatus.removed,
      );
    });

    test('tells the voter what happened in words', () {
      expect(
        describeRemovalVote(
          const MemberRemovalVote(
            status: MemberRemovalStatus.voting,
            votes: 1,
            needed: 2,
          ),
          'Bob',
        ),
        'Your vote is in. 1 more vote needed to remove Bob.',
      );
      expect(
        describeRemovalVote(
          const MemberRemovalVote(status: MemberRemovalStatus.removed),
          'Bob',
        ),
        'Bob was removed from the room.',
      );
    });
  });

  group('MemberRemovalNotifier', () {
    late _Harness harness;

    setUp(() => harness = _Harness());
    tearDown(() => harness.dispose());

    test('a vote that needs more voices asks the others', () async {
      harness.nextVote = const MemberRemovalVote(
        status: MemberRemovalStatus.voting,
        votes: 1,
        needed: 2,
      );

      final result = await harness.notifier.askToLeave(
        targetUserId: 'carol',
        targetNickname: 'Carol',
      );

      expect(result?.remaining, 1);
      expect(harness.sent.single.$1, MemberRemovalProposal.event);
      expect(harness.sent.single.$2, containsPair('target_user_id', 'carol'));
      expect(harness.sent.single.$2, containsPair('voter_nickname', 'Alice'));
    });

    test('a vote that removes the member tells the room they are out',
        () async {
      await harness.notifier.askToLeave(
        targetUserId: 'carol',
        targetNickname: 'Carol',
      );

      expect(harness.sent.single.$1, 'membership_changed');
      expect(harness.sent.single.$2, {
        'action': 'removed',
        'room_code': 'ROOM22',
        'user_id': 'carol',
      });
    });

    test('another reader\'s vote asks this reader to agree', () async {
      harness.proposals.add(_proposal(voter: 'bob', target: 'carol'));
      await pumpEventQueue();

      expect(harness.notifier.state.single.targetUserId, 'carol');
      expect(harness.notifier.state.single.voterNickname, 'Bob');
    });

    test('nobody is asked whether to remove themselves, nor about their own '
        'vote', () async {
      harness.proposals
        ..add(_proposal(voter: 'bob', target: 'alice'))
        ..add(_proposal(voter: 'alice', target: 'carol'))
        ..add(_proposal(voter: 'bob', target: 'carol', room: 'OTHER2'));
      await pumpEventQueue();

      expect(harness.notifier.state, isEmpty);
    });

    test('"not now" is not asked again by the next voter', () async {
      harness.proposals.add(_proposal(voter: 'bob', target: 'carol'));
      await pumpEventQueue();
      harness.notifier.dismiss('carol');
      expect(harness.notifier.state, isEmpty);

      harness.proposals.add(_proposal(voter: 'dave', target: 'carol'));
      await pumpEventQueue();
      expect(harness.notifier.state, isEmpty);
    });

    test('the prompt goes once the member is out', () async {
      harness.proposals.add(_proposal(voter: 'bob', target: 'carol'));
      await pumpEventQueue();

      harness.memberships.add({
        'action': 'removed',
        'room_code': 'ROOM22',
        'user_id': 'carol',
      });
      await pumpEventQueue();

      expect(harness.notifier.state, isEmpty);
      expect(harness.removedCalls, 0);
    });

    test('a vote that runs out stops asking', () async {
      final harness = _Harness(lifetime: const Duration(milliseconds: 20));
      addTearDown(harness.dispose);
      harness.proposals.add(_proposal(voter: 'bob', target: 'carol'));
      await pumpEventQueue();
      expect(harness.notifier.state, hasLength(1));

      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(harness.notifier.state, isEmpty);
    });

    test('this device checks with the database when told it was voted out',
        () async {
      harness.memberships.add({
        'action': 'removed',
        'room_code': 'ROOM22',
        'user_id': 'alice',
      });
      await pumpEventQueue();

      expect(harness.removedCalls, 1);
    });
  });
}

Map<String, dynamic> _proposal({
  required String voter,
  required String target,
  String room = 'ROOM22',
}) {
  String name(String id) => id[0].toUpperCase() + id.substring(1);
  return MemberRemovalProposal(
    roomCode: room,
    targetUserId: target,
    targetNickname: name(target),
    voterUserId: voter,
    voterNickname: name(voter),
    votes: 1,
    needed: 2,
  ).toWire();
}

class _Harness {
  final proposals = StreamController<Map<String, dynamic>>.broadcast();
  final memberships = StreamController<Map<String, dynamic>>.broadcast();
  final sent = <(String, Map<String, dynamic>)>[];
  MemberRemovalVote nextVote = const MemberRemovalVote(
    status: MemberRemovalStatus.removed,
    votes: 1,
    needed: 1,
  );
  int removedCalls = 0;
  late final MemberRemovalNotifier notifier;

  _Harness({
    Duration lifetime = MemberRemovalNotifier.defaultProposalLifetime,
  }) {
    notifier = MemberRemovalNotifier(
      proposals: proposals.stream,
      memberships: memberships.stream,
      send: (event, payload) async => sent.add((event, payload)),
      vote: (_) async => nextVote,
      onRemoved: () async => removedCalls++,
      whoAmI: () => (userId: 'alice', nickname: 'Alice', roomCode: 'ROOM22'),
      proposalLifetime: lifetime,
    );
  }

  Future<void> dispose() async {
    if (notifier.mounted) notifier.dispose();
    await proposals.close();
    await memberships.close();
  }
}
