import 'package:cotime_book/models/library_book.dart';
import 'package:cotime_book/models/room_member.dart';
import 'package:cotime_book/providers/auth_provider.dart';
import 'package:cotime_book/providers/book_provider.dart';
import 'package:cotime_book/providers/presence_provider.dart';
import 'package:cotime_book/providers/room_provider.dart';
import 'package:cotime_book/screens/room_lobby_screen.dart';
import 'package:cotime_book/services/realtime_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart'
    show RealtimeSubscribeStatus;

import 'library_test.dart' show FakeLibrary;
import 'room_provider_test.dart' show FakeRoomService, testRoom;

void main() {
  group('LobbyReadiness', () {
    const bookHash = 'book-hash';

    RoomMember member(String userId) => RoomMember(
      id: 'm-$userId',
      roomId: 'room-1',
      userId: userId,
      nickname: userId[0].toUpperCase() + userId.substring(1),
      joinedAt: DateTime.utc(2026, 8, 12),
    );

    Map<String, dynamic> online(
      String userId, {
      bool hasBook = true,
      bool isReading = false,
    }) => {
      'user_id': userId,
      'has_book': hasBook,
      'ready_book_hashes': hasBook ? [bookHash] : <String>[],
      'is_reading': isReading,
    };

    LobbyReadiness readiness({
      required List<RoomMember> members,
      required List<Map<String, dynamic>> onlineUsers,
      bool isHost = true,
      bool hasLocalBook = true,
      String? currentBookHash = bookHash,
    }) => LobbyReadiness.from(
      members: members,
      onlineUsers: onlineUsers,
      currentUserId: isHost ? 'host' : 'guest',
      currentBookHash: currentBookHash,
      hasLocalBook: hasLocalBook,
      isHost: isHost,
      isConnected: true,
    );

    test('a member whose app is gone does not lock the room out', () {
      // Regression: Start Reading required every database member to be online
      // with the book, and a crashed member stays in the database until the
      // server evicts them.
      final lobby = readiness(
        members: [member('host'), member('ghost')],
        onlineUsers: [online('host')],
      );

      expect(lobby.canOpenReader, isTrue);
      expect(lobby.isHostStart, isTrue);
      expect(lobby.hint, isNull);
    });

    test('a member still receiving the book is named, not waited for', () {
      final lobby = readiness(
        members: [member('host'), member('bob')],
        onlineUsers: [online('host'), online('bob', hasBook: false)],
      );

      expect(lobby.canOpenReader, isTrue);
      expect(lobby.hint, contains('Bob is still receiving'));
    });

    test('a guest can join a session that is already running', () {
      final idle = readiness(
        isHost: false,
        members: [member('host'), member('guest')],
        onlineUsers: [online('host'), online('guest')],
      );
      expect(idle.canOpenReader, isFalse);
      expect(idle.hint, 'The host starts the reading session.');

      final running = readiness(
        isHost: false,
        members: [member('host'), member('guest')],
        onlineUsers: [online('host', isReading: true), online('guest')],
      );
      expect(running.canOpenReader, isTrue);
      expect(running.isHostStart, isFalse);
    });

    test('the host joins a running session instead of restarting it', () {
      // "Start" broadcasts start_reading, which would pull back into the
      // reader members who had just chosen to leave it.
      final lobby = readiness(
        members: [member('host'), member('bob'), member('carol')],
        onlineUsers: [
          online('host'),
          online('bob', isReading: true),
          online('carol'),
        ],
      );
      expect(lobby.canOpenReader, isTrue);
      expect(lobby.isHostStart, isFalse);
    });

    test('nobody can open the reader without the book on this device', () {
      expect(
        readiness(
          members: [member('host')],
          onlineUsers: [online('host')],
          hasLocalBook: false,
        ).canOpenReader,
        isFalse,
      );
      expect(
        readiness(
          members: [member('host')],
          onlineUsers: [online('host')],
          currentBookHash: null,
        ).hint,
        'Share a book to start reading.',
      );
    });
  });

  group('RoomLobbyScreen roster', () {
    testWidgets(
      'a member who left while you were away is gone when the lobby opens',
      (tester) async {
        // Regression: the lobby reused the roster it had when it was last on
        // screen. Coming back from the reader, a member who had left in the
        // meantime was still listed, and since Presence did not change again
        // nothing ever corrected it.
        final rooms = FakeRoomService()
          ..members = [testMember('alice'), testMember('bob')];
        final container = await joinedContainer(tester, rooms);

        rooms.members = [testMember('alice')];
        await pumpLobby(tester, container);

        expect(member('Alice'), findsOneWidget);
        expect(member('Bob'), findsNothing);
        await disposeLobby(tester, container);
      },
    );

    testWidgets('the lobby keeps re-reading the roster on its own', (
      tester,
    ) async {
      final rooms = FakeRoomService()
        ..members = [testMember('alice'), testMember('bob')];
      final container = await joinedContainer(tester, rooms);
      await pumpLobby(tester, container);
      expect(member('Bob'), findsOneWidget);

      // Bob leaves and every signal about it is lost.
      rooms.members = [testMember('alice')];
      await tester.pump(const Duration(seconds: 1));
      expect(member('Bob'), findsOneWidget);

      await tester.pump(RoomLobbyScreen.rosterRefreshInterval);
      await tester.pump();
      expect(member('Bob'), findsNothing);
      await disposeLobby(tester, container);
    });

    testWidgets('a leave announced before its commit is read again', (
      tester,
    ) async {
      final rooms = FakeRoomService()
        ..members = [testMember('alice'), testMember('bob')];
      final container = await joinedContainer(tester, rooms);
      await pumpLobby(tester, container);

      _SilentChannel.last!.emit('membership_changed', {
        'action': 'leaving',
        'user_id': 'bob',
      });
      // The first re-read races the leave RPC and still sees Bob.
      await tester.pump(const Duration(milliseconds: 400));
      expect(member('Bob'), findsOneWidget);

      rooms.members = [testMember('alice')];
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
      expect(member('Bob'), findsNothing);
      await disposeLobby(tester, container);
    });
  });

  group('RoomLobbyScreen library', () {
    testWidgets('the library has its own button, apart from Share Book', (
      tester,
    ) async {
      final library = FakeLibrary([
        () async => const [LibraryBook(path: 'hongloumeng.epub', title: '紅樓夢')],
      ]);
      final container = await joinedContainer(
        tester,
        FakeRoomService()..members = [testMember('alice')],
        library: library,
      );
      await pumpLobby(tester, container);

      expect(find.text('Share Book'), findsOneWidget);
      expect(library.listCalls, 0);

      await tester.tap(find.text('Library'));
      await tester.pump();
      await tester.pump();

      expect(find.text('Public Library'), findsOneWidget);
      expect(find.byType(TextField), findsOneWidget);
      expect(find.text('紅樓夢'), findsWidgets);
      expect(library.listCalls, 1);

      Navigator.of(tester.element(find.text('Public Library'))).pop();
      await tester.pump();
      await disposeLobby(tester, container);
    });
  });
}

RoomMember testMember(String userId) => RoomMember(
  id: 'm-$userId',
  roomId: testRoom().id,
  userId: userId,
  nickname: userId[0].toUpperCase() + userId.substring(1),
  joinedAt: DateTime.utc(2026, 8, 12),
);

class _SignedInAuth extends AuthNotifier {
  _SignedInAuth() {
    state = const AuthState(userId: 'alice', nickname: 'Alice');
  }
}

Future<ProviderContainer> joinedContainer(
  WidgetTester tester,
  FakeRoomService rooms, {
  FakeLibrary? library,
}) async {
  final realtime = RealtimeService(
    channelFactory: (name, key) => _SilentChannel(),
  );
  final container = ProviderContainer(
    overrides: [
      roomServiceProvider.overrideWithValue(rooms),
      realtimeServiceProvider.overrideWithValue(realtime),
      authProvider.overrideWith((ref) => _SignedInAuth()),
      if (library != null) libraryServiceProvider.overrideWithValue(library),
    ],
  );
  await container
      .read(roomProvider.notifier)
      .joinRoom(testRoom().code, 'Alice');
  return container;
}

Future<void> pumpLobby(WidgetTester tester, ProviderContainer container) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(home: RoomLobbyScreen(roomCode: testRoom().code)),
    ),
  );
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 10));
  }
}

/// A member row; the current user's row reads "Alice  (You)".
Finder member(String nickname) =>
    find.textContaining(RegExp('^$nickname\\b'), findRichText: true);

/// Unmounts the lobby and the room so their periodic timers stop before the
/// test ends.
Future<void> disposeLobby(
  WidgetTester tester,
  ProviderContainer container,
) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 5));
  // overrideWithValue does not dispose the service with the container, and
  // its connection watchdog holds a timer.
  final closing = container.read(realtimeServiceProvider).close();
  await tester.pump();
  await closing;
  container.dispose();
}

/// A channel that never connects: the lobby must work from the database
/// alone.
class _SilentChannel implements RoomRealtimeChannel {
  static _SilentChannel? last;
  final _callbacks = <String, ValueChanged<Map<String, dynamic>>>{};

  _SilentChannel() {
    last = this;
  }

  void emit(String event, Map<String, dynamic> payload) =>
      _callbacks[event]?.call(payload);

  @override
  void onPresenceSync(VoidCallback callback) {}

  @override
  void onPresenceJoin(ValueChanged<dynamic> callback) {}

  @override
  void onPresenceLeave(ValueChanged<dynamic> callback) {}

  @override
  void onBroadcast(String event, ValueChanged<Map<String, dynamic>> callback) {
    _callbacks[event] = callback;
  }

  @override
  void subscribe(
    void Function(RealtimeSubscribeStatus status, Object? error) callback,
  ) {}

  @override
  Future<void> track(Map<String, dynamic> payload) async {}

  @override
  Future<void> untrack() async {}

  @override
  Future<void> sendBroadcast(
    String event,
    Map<String, dynamic> payload,
  ) async {}

  @override
  List<Map<String, dynamic>> presencePayloads() => const [];

  @override
  Future<void> remove({bool releaseSocket = true}) async {}
}
