import 'dart:math';

/// How a vote to remove a member came out (`vote_remove_member`).
enum MemberRemovalStatus {
  /// This vote completed it: the member is out of the room.
  removed,

  /// Recorded, and more votes are needed.
  voting,

  /// The member was not in the room any more (left, or removed already).
  gone,
}

class MemberRemovalVote {
  final MemberRemovalStatus status;
  final int votes;
  final int needed;

  const MemberRemovalVote({
    required this.status,
    this.votes = 0,
    this.needed = 0,
  });

  factory MemberRemovalVote.fromJson(Map<String, dynamic> json) {
    final status = switch (json['status']) {
      'removed' => MemberRemovalStatus.removed,
      'voting' => MemberRemovalStatus.voting,
      _ => MemberRemovalStatus.gone,
    };
    return MemberRemovalVote(
      status: status,
      votes: _int(json['votes']),
      needed: _int(json['needed']),
    );
  }

  int get remaining => max(0, needed - votes);

  /// "1 more vote", "2 more votes".
  static String moreVotes(int remaining) =>
      '$remaining more ${remaining == 1 ? 'vote' : 'votes'}';

  static int _int(Object? value) => switch (value) {
    final int number => number,
    final num number => number.toInt(),
    final String text => int.tryParse(text) ?? 0,
    _ => 0,
  };
}

/// Someone in the room voted to remove [targetUserId] and the vote needs more
/// voices. Sent over Broadcast so the others are asked; the count itself is
/// the database's, and a lost proposal only means nobody is prompted.
class MemberRemovalProposal {
  static const event = 'member_removal_vote';

  final String roomCode;
  final String targetUserId;
  final String targetNickname;
  final String voterUserId;
  final String voterNickname;
  final int votes;
  final int needed;

  const MemberRemovalProposal({
    required this.roomCode,
    required this.targetUserId,
    required this.targetNickname,
    required this.voterUserId,
    required this.voterNickname,
    required this.votes,
    required this.needed,
  });

  int get remaining => max(0, needed - votes);

  Map<String, dynamic> toWire() => {
    'room_code': roomCode,
    'target_user_id': targetUserId,
    'target_nickname': targetNickname,
    'voter_user_id': voterUserId,
    'voter_nickname': voterNickname,
    'votes': votes,
    'needed': needed,
  };

  static MemberRemovalProposal? fromWire(Map<String, dynamic> payload) {
    final roomCode = payload['room_code'];
    final target = payload['target_user_id'];
    final voter = payload['voter_user_id'];
    if (roomCode is! String || target is! String || voter is! String) {
      return null;
    }
    return MemberRemovalProposal(
      roomCode: roomCode,
      targetUserId: target,
      targetNickname: _name(payload['target_nickname']),
      voterUserId: voter,
      voterNickname: _name(payload['voter_nickname']),
      votes: MemberRemovalVote._int(payload['votes']),
      needed: MemberRemovalVote._int(payload['needed']),
    );
  }

  static String _name(Object? value) =>
      value is String && value.trim().isNotEmpty ? value.trim() : 'A reader';
}
