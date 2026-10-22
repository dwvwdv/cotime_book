import 'dart:async';
import 'dart:typed_data';

import 'package:cotime_book/config/app_constants.dart';
import 'package:cotime_book/models/library_book.dart';
import 'package:cotime_book/models/room.dart';
import 'package:cotime_book/models/room_member.dart';
import 'package:cotime_book/providers/auth_provider.dart';
import 'package:cotime_book/providers/book_provider.dart';
import 'package:cotime_book/providers/presence_provider.dart';
import 'package:cotime_book/providers/room_provider.dart';
import 'package:cotime_book/screens/room_lobby_screen.dart';
import 'package:cotime_book/services/library_service.dart';
import 'package:cotime_book/services/realtime_service.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart'
    show RealtimeSubscribeStatus;

import 'book_provider_test.dart' show MemoryEpubStorage;
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

    test('members on another app version are named, in words (GH-33)', () {
      // Their page turns and transfers and this app's ignore each other.
      final behind = readiness(
        members: [member('host'), member('bob')],
        onlineUsers: [
          {
            ...online('host'),
            'protocols': [1],
          },
          {
            ...online('bob'),
            'protocols': [0],
          },
        ],
      );
      expect(
        behind.versionNotice,
        'Bob needs to update CoTime Book to read together.',
      );
      // Not a reason to keep the room from reading.
      expect(behind.canOpenReader, isTrue);

      final ahead = readiness(
        members: [member('host'), member('bob')],
        onlineUsers: [
          {
            ...online('host'),
            'protocols': [1],
          },
          {
            ...online('bob'),
            'protocols': [99],
          },
        ],
      );
      expect(ahead.versionNotice, startsWith('Your app is out of date'));

      final same = readiness(
        members: [member('host'), member('bob')],
        onlineUsers: [
          {
            ...online('host'),
            'protocols': [1],
          },
          {
            ...online('bob'),
            'protocols': [1],
          },
        ],
      );
      expect(same.versionNotice, isNull);
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

  group('RoomLobbyScreen app versions', () {
    testWidgets('a member on an older app is marked as needing an update', (
      tester,
    ) async {
      // GH-33: an app from before the protocol field sends none.
      final rooms = FakeRoomService()
        ..members = [testMember('alice'), testMember('bob')];
      final container = await joinedContainer(tester, rooms);
      await pumpLobby(tester, container);
      expect(find.text('Needs app update'), findsNothing);

      _SilentChannel.last!.connect([
        {
          'user_id': 'alice',
          'nickname': 'Alice',
          'protocol': AppConstants.roomProtocolVersion,
        },
        {'user_id': 'bob', 'nickname': 'Bob'},
      ]);
      await tester.pump();
      await tester.pump();

      expect(find.text('Needs app update'), findsOneWidget);
      expect(
        find.text('Bob needs to update CoTime Book to read together.'),
        findsOneWidget,
      );
      await disposeLobby(tester, container);
    });
  });

  group('RoomLobbyScreen removed from the room', () {
    testWidgets('goes home and says why when the membership is gone', (
      tester,
    ) async {
      // GH-36: Realtime refused the channel, and the database agrees.
      final rooms = FakeRoomService()..members = [testMember('alice')];
      final container = await joinedContainer(tester, rooms);
      await pumpRoutedLobby(tester, container);
      expect(find.text('Room Lobby'), findsOneWidget);

      rooms.roomRead = Completer<Room?>()..complete(null);
      _SilentChannel.last!.refuse();
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 10));
      }

      expect(find.text('HOME'), findsOneWidget);
      expect(find.text(RoomNotifier.removedFromRoomMessage), findsOneWidget);
      // Said once; not left behind as a banner on Home.
      expect(container.read(roomProvider).error, isNull);
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

    testWidgets(
      'a member who arrives after a library share downloads it from the library',
      (tester) async {
        // GH-28: the library path was only in the share broadcast, so someone
        // who opened the lobby afterwards waited on the slower peer-to-peer
        // transfer, which also needs a member holding the book to be online.
        // A phone-sized screen: the default 800x600 test view is too short
        // for the lobby with both the transfer and the book card showing.
        tester.view.physicalSize = const Size(1080, 2400);
        tester.view.devicePixelRatio = 3;
        addTearDown(tester.view.reset);
        final storage = MemoryEpubStorage();
        addTearDown(() => storage.dir.deleteSync(recursive: true));
        final library = _PendingLibrary();
        final book = Uint8List.fromList(List.generate(4000, (i) => i % 13));
        final rooms = FakeRoomService()
          ..members = [testMember('alice'), testMember('bob')]
          ..nextRoom = testRoom().copyWith(
            currentBookTitle: 'Moby-Dick',
            currentBookHash: sha256.convert(book).toString(),
            currentBookLibraryPath: 'classics/moby-dick.epub',
          );
        final container = await joinedContainer(
          tester,
          rooms,
          library: library,
          storage: storage,
        );
        await pumpLobby(tester, container);

        expect(library.downloads.keys, ['classics/moby-dick.epub']);
        expect(
          find.text('Downloading the book from the library...'),
          findsOneWidget,
        );

        library.downloads['classics/moby-dick.epub']!.complete(book);
        for (var i = 0; i < 5; i++) {
          await tester.pump(const Duration(milliseconds: 10));
        }
        expect(find.text('Book received'), findsOneWidget);
        await disposeLobby(tester, container);
      },
    );
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
  LibraryService? library,
  MemoryEpubStorage? storage,
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
      if (storage != null) epubStorageProvider.overrideWithValue(storage),
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

/// The lobby inside a router, for tests that leave it.
Future<void> pumpRoutedLobby(
  WidgetTester tester,
  ProviderContainer container,
) async {
  final router = GoRouter(
    initialLocation: '/lobby/${testRoom().code}',
    routes: [
      GoRoute(
        path: '/',
        name: 'home',
        builder: (context, state) => const Scaffold(body: Text('HOME')),
      ),
      GoRoute(
        path: '/lobby/:roomCode',
        name: 'lobby',
        builder: (context, state) =>
            RoomLobbyScreen(roomCode: state.pathParameters['roomCode']!),
      ),
    ],
  );
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(routerConfig: router),
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

/// A library whose downloads finish when the test says so.
class _PendingLibrary implements LibraryService {
  final downloads = <String, Completer<Uint8List>>{};

  @override
  Future<List<LibraryBook>> listBooks() async => const [];

  @override
  Future<Uint8List> download(String path) =>
      (downloads[path] = Completer<Uint8List>()).future;

  @override
  String coverUrl(String path) => 'https://library.test/$path';
}

/// A channel that never connects: the lobby must work from the database
/// alone.
class _SilentChannel implements RoomRealtimeChannel {
  static _SilentChannel? last;
  final _callbacks = <String, ValueChanged<Map<String, dynamic>>>{};
  void Function(RealtimeSubscribeStatus, Object?)? _status;
  VoidCallback? _sync;
  List<Map<String, dynamic>> presences = const [];

  _SilentChannel() {
    last = this;
  }

  void emit(String event, Map<String, dynamic> payload) =>
      _callbacks[event]?.call(payload);

  /// Connects after all, with [presences] online.
  void connect(List<Map<String, dynamic>> presences) {
    this.presences = presences;
    _status?.call(RealtimeSubscribeStatus.subscribed, null);
    _sync?.call();
  }

  /// The server refuses this user the room's topic.
  void refuse() => _status?.call(
    RealtimeSubscribeStatus.channelError,
    Exception(
      '"Unauthorized: You do not have permissions to read from this Channel '
      'topic: cotime_book:room:${testRoom().code}"',
    ),
  );

  @override
  void onPresenceSync(VoidCallback callback) => _sync = callback;

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
  ) => _status = callback;

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
  List<Map<String, dynamic>> presencePayloads() => presences;

  @override
  Future<void> remove({bool releaseSocket = true}) async {}
}
