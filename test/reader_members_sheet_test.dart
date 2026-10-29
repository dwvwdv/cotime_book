import 'package:cotime_book/models/room_member.dart';
import 'package:cotime_book/providers/auth_provider.dart';
import 'package:cotime_book/providers/presence_provider.dart';
import 'package:cotime_book/providers/room_provider.dart';
import 'package:cotime_book/services/realtime_service.dart';
import 'package:cotime_book/services/room_service.dart';
import 'package:cotime_book/widgets/reader_members_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakePresenceNotifier extends PresenceNotifier {
  _FakePresenceNotifier() : super(RealtimeService());

  void emit(List<Map<String, dynamic>> users) {
    state = state.copyWith(onlineUsers: users);
  }
}

class _Roster extends RoomNotifier {
  _Roster(List<RoomMember> members) : super(RoomService()) {
    state = state.copyWith(members: members);
  }

  @override
  Future<void> refreshMembers({
    List<Map<String, dynamic>>? presenceUsers,
  }) async {}
}

class _SignedInAuth extends AuthNotifier {
  _SignedInAuth() {
    state = const AuthState(userId: 'alice', nickname: 'Alice');
  }
}

RoomMember _member(String userId, String nickname) => RoomMember(
  id: 'm-$userId',
  roomId: 'room',
  userId: userId,
  nickname: nickname,
  joinedAt: DateTime.utc(2026, 10, 29),
);

void main() {
  testWidgets('the reader everyone is waiting for is listed, and can be '
      'voted out', (tester) async {
    // Bob closed the app: he is not in Presence, so a list built from
    // Presence alone never showed the one person holding the room up.
    final presence = _FakePresenceNotifier();
    presence.emit([
      {'user_id': 'alice', 'nickname': 'Alice', 'is_reading': true},
    ]);
    final asked = <String>[];

    await tester.pumpWidget(ProviderScope(
      overrides: [
        presenceProvider.overrideWith((ref) => presence),
        authProvider.overrideWith((ref) => _SignedInAuth()),
        roomProvider.overrideWith(
          (ref) => _Roster([_member('alice', 'Alice'), _member('bob', 'Bob')]),
        ),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: ReaderMembersSheet(
            onAskToLeave: (userId, nickname) => asked.add(userId),
          ),
        ),
      ),
    ));
    await tester.pump();

    expect(find.text('Bob'), findsOneWidget);
    expect(find.text('Not connected'), findsOneWidget);
    expect(find.byTooltip('Ask Alice to leave'), findsNothing);

    await tester.tap(find.byTooltip('Ask Bob to leave'));
    expect(asked, ['bob']);
  });

  testWidgets('the members panel follows people coming and going while open',
      (tester) async {
    final presence = _FakePresenceNotifier();
    presence.emit([
      {'user_id': 'alice', 'nickname': 'Alice', 'is_reading': true},
    ]);

    await tester.pumpWidget(ProviderScope(
      overrides: [presenceProvider.overrideWith((ref) => presence)],
      child: const MaterialApp(home: Scaffold(body: ReaderMembersSheet())),
    ));

    expect(find.text('Alice'), findsOneWidget);
    expect(find.text('Bob'), findsNothing);

    presence.emit([
      {'user_id': 'alice', 'nickname': 'Alice', 'is_reading': false},
      {'user_id': 'bob', 'nickname': 'Bob', 'is_reading': true},
    ]);
    await tester.pump();

    expect(find.text('Bob'), findsOneWidget);
    expect(find.text('2 Members Online'), findsOneWidget);
    expect(find.text('Left the reader'), findsOneWidget);
  });
}
