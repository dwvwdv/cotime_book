import 'package:cotime_book/providers/presence_provider.dart';
import 'package:cotime_book/services/realtime_service.dart';
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

void main() {
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
