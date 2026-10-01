import 'package:cotime_book/models/recent_room.dart';
import 'package:cotime_book/providers/auth_provider.dart';
import 'package:cotime_book/providers/local_store_provider.dart';
import 'package:cotime_book/providers/room_provider.dart';
import 'package:cotime_book/screens/home_screen.dart';
import 'package:cotime_book/services/local_store.dart';
import 'package:cotime_book/services/room_service.dart';
import 'package:cotime_book/widgets/recent_rooms_list.dart';
import 'package:cotime_book/widgets/room_code_input.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'room_provider_test.dart' show FakeRoomService, testRoom;

class _SignedInAuth extends AuthNotifier {
  _SignedInAuth(super.store) {
    state = state.copyWith(userId: 'alice');
  }
}

void main() {
  late LocalStore store;
  late FakeRoomService rooms;
  late ProviderContainer container;
  late List<String> visitedLobbies;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    store = LocalStore(await SharedPreferences.getInstance());
    rooms = FakeRoomService();
    visitedLobbies = [];
  });

  Future<void> pumpHome(WidgetTester tester) async {
    container = ProviderContainer(
      overrides: [
        localStoreProvider.overrideWithValue(store),
        roomServiceProvider.overrideWithValue(rooms),
        authProvider.overrideWith((ref) => _SignedInAuth(store)),
      ],
    );
    addTearDown(container.dispose);
    final router = GoRouter(
      routes: [
        GoRoute(path: '/', builder: (_, _) => const HomeScreen()),
        GoRoute(
          path: '/lobby/:roomCode',
          name: 'lobby',
          builder: (_, state) {
            visitedLobbies.add(state.pathParameters['roomCode']!);
            return const Scaffold(body: Text('Lobby'));
          },
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(routerConfig: router),
      ),
    );
  }

  /// Leaves the lobby's room so its heartbeat timer stops before the test ends.
  Future<void> leave(WidgetTester tester) async {
    await container.read(roomProvider.notifier).leaveRoom();
    await tester.pumpWidget(const SizedBox());
  }

  testWidgets('the nickname from last time is already filled in', (
    tester,
  ) async {
    await store.saveNickname('Alice');
    await pumpHome(tester);

    expect(find.widgetWithText(TextField, 'Alice'), findsOneWidget);
  });

  testWidgets('the room code field asks for an English keyboard', (
    tester,
  ) async {
    await pumpHome(tester);
    await tester.tap(find.text('Join Room'));
    await tester.pump();

    final field = tester.widget<TextField>(
      find.descendant(
        of: find.byType(RoomCodeInput),
        matching: find.byType(TextField),
      ),
    );
    expect(field.keyboardType, TextInputType.visiblePassword);
    expect(field.autocorrect, isFalse);
  });

  testWidgets('a room you joined shows up under recent rooms', (tester) async {
    rooms.nextRoom = testRoom(
      code: 'ABC234',
    ).copyWith(currentBookTitle: 'Moby-Dick');
    await store.saveNickname('Alice');
    await pumpHome(tester);

    await tester.tap(find.text('Join Room'));
    await tester.pump();
    await tester.enterText(find.byType(RoomCodeInput), 'abc234');
    await tester.tap(find.widgetWithText(ElevatedButton, 'Join Room'));
    await tester.pumpAndSettle();
    await leave(tester);

    final saved = (LocalStore(
      await SharedPreferences.getInstance(),
    )).recentRooms.single;
    expect(saved.code, 'ABC234');
    expect(saved.bookTitle, 'Moby-Dick');
  });

  testWidgets('tapping a recent room goes straight back in', (tester) async {
    rooms.nextRoom = testRoom(code: 'ABC234');
    await store.saveNickname('Alice');
    await store.saveRecentRooms([
      RecentRoom(
        code: 'ABC234',
        bookTitle: 'Moby-Dick',
        lastVisitedAt: DateTime.now(),
      ),
    ]);
    await pumpHome(tester);

    expect(find.text('Moby-Dick · Today'), findsOneWidget);
    await tester.tap(find.text('ABC234'));
    await tester.pumpAndSettle();

    expect(rooms.joinedCodes, ['ABC234']);
    expect(visitedLobbies, ['ABC234']);
    await leave(tester);
  });

  testWidgets('a recent room that is gone says so and leaves the list', (
    tester,
  ) async {
    rooms.joinError = const RoomNotFoundException('ABC234');
    await store.saveNickname('Alice');
    await store.saveRecentRooms([
      RecentRoom(code: 'ABC234', lastVisitedAt: DateTime.now()),
    ]);
    await pumpHome(tester);

    await tester.tap(find.text('ABC234'));
    await tester.pumpAndSettle();

    expect(visitedLobbies, isEmpty);
    expect(rooms.createCalls, 0);
    expect(find.text('Room ABC234 is no longer available.'), findsOneWidget);
    expect(find.byType(RecentRoomsList), findsNothing);
    expect(store.recentRooms, isEmpty);
  });

  testWidgets('rooms deleted while the app was closed are not listed', (
    tester,
  ) async {
    // Closed rooms are deleted 30 days after closing; the server is the only
    // one who knows when that happened.
    rooms.availableCodes = {'BBBBBB'};
    await store.saveRecentRooms([
      RecentRoom(code: 'AAAAAA', lastVisitedAt: DateTime.now()),
      RecentRoom(code: 'BBBBBB', lastVisitedAt: DateTime.now()),
    ]);
    await pumpHome(tester);
    await tester.pump();

    expect(find.text('AAAAAA'), findsNothing);
    expect(find.text('BBBBBB'), findsOneWidget);
    expect(store.recentRooms.map((r) => r.code), ['BBBBBB']);
  });

  testWidgets('being offline does not empty the recent list', (tester) async {
    rooms.availabilityError = StateError('no network');
    await store.saveRecentRooms([
      RecentRoom(code: 'AAAAAA', lastVisitedAt: DateTime.now()),
    ]);
    await pumpHome(tester);
    await tester.pump();

    expect(find.text('AAAAAA'), findsOneWidget);
  });

  testWidgets('a recent room can be forgotten', (tester) async {
    await store.saveRecentRooms([
      RecentRoom(code: 'ABC234', lastVisitedAt: DateTime.now()),
    ]);
    await pumpHome(tester);

    await tester.tap(find.byTooltip('Remove ABC234 from recent rooms'));
    await tester.pump();

    expect(find.byType(RecentRoomsList), findsNothing);
    expect(store.recentRooms, isEmpty);
  });

  test('visit dates read as words', () {
    final now = DateTime(2026, 10, 1, 9);
    expect(describeVisit(DateTime(2026, 10, 1, 0, 5), now), 'Today');
    expect(describeVisit(DateTime(2026, 9, 30, 23, 50), now), 'Yesterday');
    expect(describeVisit(DateTime(2026, 9, 27, 12), now), '4 days ago');
    expect(describeVisit(DateTime(2026, 8, 3), now), '2026-08-03');
  });
}
