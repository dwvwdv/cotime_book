import 'dart:async';

import 'package:cotime_book/models/room.dart';
import 'package:cotime_book/models/room_member.dart';
import 'package:cotime_book/providers/room_provider.dart';
import 'package:cotime_book/services/room_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('RoomNotifier', () {
    test('the host\'s text size change lands in the room at once', () async {
      final service = FakeRoomService();
      final notifier = RoomNotifier(service);
      addTearDown(notifier.dispose);
      await notifier.joinRoom('ABC234', 'Alice');

      expect(
        await notifier.setRoomTextSize(locked: true, textSize: 24),
        isTrue,
      );

      expect(service.textSizeWrites, [(true, 24)]);
      expect(notifier.state.currentRoom?.textSize, 24);
      expect(notifier.state.currentRoom?.textSizeLocked, isTrue);
    });

    test('a refused text size change re-reads the room and keeps it', () async {
      // The refusal usually means someone else is host now: the room as the
      // database has it is what the settings must show, and the reader stays.
      final service = FakeRoomService();
      final notifier = RoomNotifier(service);
      addTearDown(notifier.dispose);
      await notifier.joinRoom('ABC234', 'Alice');
      final readsBefore = service.roomReads;
      service.textSizeError = Exception('Only the host can change it');

      expect(await notifier.setRoomTextSize(locked: false), isFalse);

      expect(service.roomReads, readsBefore + 1);
      expect(notifier.state.currentRoom, isNotNull);
      expect(notifier.state.error, isNull);
    });

    test('a text size change from a reader no longer in the room leaves it',
        () async {
      final service = FakeRoomService();
      final notifier = RoomNotifier(service);
      addTearDown(notifier.dispose);
      await notifier.joinRoom('ABC234', 'Alice');
      service.textSizeError = const RoomSessionRevokedException('gone');

      expect(
        await notifier.setRoomTextSize(locked: true, textSize: 20),
        isFalse,
      );

      expect(notifier.state.currentRoom, isNull);
      expect(notifier.state.error, 'gone');
    });

    test('a quiet re-read that fails puts up no error', () async {
      // The reader re-reads the room every 30 seconds for the text size; a
      // failed background read must not leave a message up (GH-30).
      final service = FakeRoomService();
      final notifier = RoomNotifier(service);
      addTearDown(notifier.dispose);
      await notifier.joinRoom('ABC234', 'Alice');
      service.roomReadError = Exception('offline');

      await notifier.refreshRoom(quiet: true);
      expect(notifier.state.error, isNull);

      await notifier.refreshRoom();
      expect(notifier.state.error, contains('offline'));
    });

    test('overlapping position saves never leave an older page behind', () async {
      // Regression: two saves raced; the newer committed first and the older
      // one's conflict retry then wrote the older page over it.
      final service = FakeRoomService();
      final notifier = RoomNotifier(service);
      addTearDown(notifier.dispose);
      await notifier.joinRoom('ABC234', 'Alice');

      final firstWrite = Completer<Room>();
      service.cfiWrite = firstWrite;
      final saves = [
        notifier.saveReadingPosition('page-1'),
        notifier.saveReadingPosition('page-2'),
        notifier.saveReadingPosition('page-3'),
      ];
      await Future<void>.delayed(Duration.zero);
      service.cfiWrite = null;
      firstWrite.complete(
        service.nextRoom.copyWith(currentCfi: 'page-1', revision: 1),
      );
      await Future.wait(saves);

      expect(service.cfiWrites, ['page-1', 'page-3']);
      expect(notifier.state.currentRoom?.currentCfi, 'page-3');
    });

    test('a recent room that is still open is joined, not recreated', () async {
      final service = FakeRoomService()..nextRoom = testRoom(code: 'ABC234');
      final notifier = RoomNotifier(service);
      addTearDown(notifier.dispose);

      final result = await notifier.rejoinRoom('ABC234', 'Alice');

      expect(result.room?.code, 'ABC234');
      expect(result.gone, isFalse);
      expect(service.createCalls, 0);
      expect(notifier.state.currentRoom?.code, 'ABC234');
    });

    test('a recent room that is gone does not open a new room', () async {
      // A new room would have a new code nobody else knows; the person asked
      // to go back to the old one, not to start over.
      final service = FakeRoomService()
        ..joinError = const RoomNotFoundException('ABC234');
      final notifier = RoomNotifier(service);
      addTearDown(notifier.dispose);

      final result = await notifier.rejoinRoom('ABC234', 'Alice');

      expect(result.room, isNull);
      expect(result.gone, isTrue);
      expect(service.createCalls, 0);
      expect(notifier.state.currentRoom, isNull);
      expect(notifier.state.error, 'Room ABC234 is no longer available.');
    });

    test('a failed rejoin that is not "gone" keeps the room listed', () async {
      final service = FakeRoomService()
        ..joinError = StateError('connection reset');
      final notifier = RoomNotifier(service);
      addTearDown(notifier.dispose);

      final result = await notifier.rejoinRoom('ABC234', 'Alice');

      expect(result.room, isNull);
      expect(result.gone, isFalse);
    });

    test('joining a closed room by code says so in words', () async {
      final service = FakeRoomService()
        ..joinError = const RoomNotFoundException('ABC234');
      final notifier = RoomNotifier(service);
      addTearDown(notifier.dispose);

      expect(await notifier.joinRoom('ABC234', 'Alice'), isNull);
      expect(service.createCalls, 0);
      expect(notifier.state.error, 'Room ABC234 is no longer available.');
    });

    test('a dropped leave request is sent again', () async {
      // Regression: one failed leave RPC left the member in everyone else's
      // list until the server evicted them half an hour later.
      final service = FakeRoomService()..leaveFailures = 1;
      final notifier = RoomNotifier(service);
      addTearDown(notifier.dispose);

      await notifier.joinRoom('ABC234', 'Alice');
      await notifier.leaveRoom();

      expect(service.leaveCalls, 2);
      expect(notifier.state.currentRoom, isNull);
    });

    test('revoked heartbeat clears local room session and runs teardown', () async {
      final service = FakeRoomService()..heartbeatError =
          const RoomSessionRevokedException('membership expired');
      var teardownCalls = 0;
      final notifier = RoomNotifier(
        service,
        onSessionRevoked: () async {
          teardownCalls++;
        },
      );
      addTearDown(notifier.dispose);

      await notifier.createRoom('Alice');
      await expectLater(
        notifier.heartbeat(),
        throwsA(isA<RoomSessionRevokedException>()),
      );

      expect(notifier.state.currentRoom, isNull);
      expect(notifier.state.members, isEmpty);
      expect(notifier.state.error, 'membership expired');
      expect(teardownCalls, 1);
    });

    test('a heartbeat refused after leaving does not report a revocation', () async {
      // Regression: a heartbeat still in flight when the user tapped Leave
      // came back refused (the leave RPC had run first), and home showed
      // "membership expired" after an ordinary leave.
      final service = FakeRoomService()
        ..heartbeatReply = Completer<Room>()
        ..leaveReply = Completer<void>();
      var teardownCalls = 0;
      final notifier = RoomNotifier(
        service,
        onSessionRevoked: () async {
          teardownCalls++;
        },
      );
      addTearDown(notifier.dispose);

      await notifier.createRoom('Alice');
      final heartbeat = notifier.heartbeat();
      final leaving = notifier.leaveRoom();
      // The server ran leave_room first, so the heartbeat is refused while
      // the leave's own reply is still on its way.
      service.heartbeatReply!.completeError(
        const RoomSessionRevokedException('membership expired'),
      );
      await expectLater(
        heartbeat,
        throwsA(isA<RoomSessionRevokedException>()),
      );
      service.leaveReply!.complete();
      await leaving;

      expect(notifier.state.currentRoom, isNull);
      expect(notifier.state.error, isNull);
      expect(teardownCalls, 0);
    });

    test('transient heartbeat failure preserves the active session', () async {
      final service = FakeRoomService()
        ..heartbeatError = StateError('temporary network failure');
      final notifier = RoomNotifier(service);
      addTearDown(notifier.dispose);

      final room = await notifier.createRoom('Alice');
      await expectLater(notifier.heartbeat(), throwsStateError);

      expect(notifier.state.currentRoom?.id, room?.id);
      expect(notifier.state.error, contains('temporary network failure'));
    });

    test('revoked CFI write also tears down the cached session', () async {
      final service = FakeRoomService()
        ..cfiError = const RoomSessionRevokedException('membership expired');
      var teardownCalls = 0;
      final notifier = RoomNotifier(
        service,
        onSessionRevoked: () async {
          teardownCalls++;
        },
      );
      addTearDown(notifier.dispose);

      final room = await notifier.createRoom('Alice');
      await expectLater(
        notifier.updateCfiForRoom(
          roomId: room!.id,
          cfi: 'epubcfi(/6/8)',
        ),
        throwsA(isA<RoomSessionRevokedException>()),
      );

      expect(notifier.state.currentRoom, isNull);
      expect(notifier.state.error, 'membership expired');
      expect(teardownCalls, 1);
    });

    test('revoked book write also tears down the cached session', () async {
      final service = FakeRoomService()
        ..bookError =
            const RoomSessionRevokedException('membership expired');
      var teardownCalls = 0;
      final notifier = RoomNotifier(
        service,
        onSessionRevoked: () async {
          teardownCalls++;
        },
      );
      addTearDown(notifier.dispose);

      await notifier.createRoom('Alice');
      await expectLater(
        notifier.updateBookShared(
          bookTitle: 'Revoked Book',
          bookHash: List.filled(64, 'c').join(),
        ),
        throwsA(isA<RoomSessionRevokedException>()),
      );

      expect(notifier.state.currentRoom, isNull);
      expect(notifier.state.error, 'membership expired');
      expect(teardownCalls, 1);
    });

    test('room-specific CFI writes cannot update a later room session', () async {
      final service = FakeRoomService();
      final notifier = RoomNotifier(service);
      addTearDown(notifier.dispose);

      final roomA = await notifier.createRoom('Alice');
      final delayedWrite = Completer<Room>();
      service.cfiWrite = delayedWrite;
      final write = notifier.updateCfiForRoom(
        roomId: roomA!.id,
        cfi: 'epubcfi(/6/8)',
      );
      await Future<void>.delayed(Duration.zero);

      await notifier.leaveRoom();
      service.nextRoom = testRoom(id: 'room-b', code: 'BBBBBB');
      await notifier.createRoom('Alice');
      delayedWrite.complete(
        roomA.copyWith(currentCfi: 'epubcfi(/6/8)'),
      );
      await expectLater(
        write,
        throwsA(isA<RoomSessionChangedException>()),
      );

      expect(notifier.state.currentRoom?.id, 'room-b');
      expect(notifier.state.currentRoom?.currentCfi, isNull);
      await expectLater(
        notifier.updateCfiForRoom(
          roomId: roomA.id,
          cfi: 'epubcfi(/6/10)',
        ),
        throwsA(isA<RoomSessionChangedException>()),
      );
    });

    test('a delayed CFI write cannot cross a same-room rejoin', () async {
      final service = FakeRoomService();
      final notifier = RoomNotifier(service);
      addTearDown(notifier.dispose);

      final room = await notifier.createRoom('Alice');
      final delayedWrite = Completer<Room>();
      service.cfiWrite = delayedWrite;
      final write = notifier.updateCfiForRoom(
        roomId: room!.id,
        cfi: 'epubcfi(/6/14)',
      );
      await Future<void>.delayed(Duration.zero);

      await notifier.leaveRoom();
      service.nextRoom = testRoom(id: room.id, code: room.code);
      await notifier.joinRoom(room.code, 'Alice');
      delayedWrite.complete(room.copyWith(currentCfi: 'epubcfi(/6/14)'));

      await expectLater(
        write,
        throwsA(isA<RoomSessionChangedException>()),
      );
      expect(notifier.state.currentRoom?.id, room.id);
      expect(notifier.state.currentRoom?.currentCfi, isNull);
      expect(service.lastCfiExpectedRevision, 0);
    });

    test('a delayed member refresh cannot overwrite a later room', () async {
      final service = FakeRoomService();
      final notifier = RoomNotifier(service);
      addTearDown(notifier.dispose);

      await notifier.createRoom('Alice');
      final delayedMembers = Completer<List<RoomMember>>();
      service.memberRead = delayedMembers;
      final refresh = notifier.refreshMembers();
      await Future<void>.delayed(Duration.zero);

      await notifier.leaveRoom();
      service.memberRead = null;
      service.nextRoom = testRoom(id: 'room-b', code: 'BBBBBB');
      await notifier.createRoom('Alice');
      delayedMembers.complete([testMember(roomId: 'room-a')]);
      await refresh;

      expect(notifier.state.currentRoom?.id, 'room-b');
      expect(notifier.state.members, isEmpty);
    });

    test('a delayed member snapshot cannot overwrite newer presence', () async {
      final service = FakeRoomService()
        ..members = [testMember(roomId: 'room-a')];
      final notifier = RoomNotifier(service);
      addTearDown(notifier.dispose);

      await notifier.createRoom('Alice');
      final delayedMembers = Completer<List<RoomMember>>();
      service.memberRead = delayedMembers;
      final refresh = notifier.refreshMembers();
      await Future<void>.delayed(Duration.zero);

      notifier.updateMembersFromPresence([
        {
          'user_id': 'user-a',
          'has_book': true,
        },
      ]);
      delayedMembers.complete([testMember(roomId: 'room-a')]);
      await refresh;

      expect(notifier.state.members.single.hasBook, isTrue);
      expect(notifier.state.members.single.isOnline, isTrue);
    });

    test('a member who joins mid-refresh survives a presence overlay', () async {
      final service = FakeRoomService()..members = [testMember(roomId: 'room-a')];
      final notifier = RoomNotifier(service);
      addTearDown(notifier.dispose);

      await notifier.createRoom('Alice');
      final delayedMembers = Completer<List<RoomMember>>();
      service.memberRead = delayedMembers;
      final refresh = notifier.refreshMembers(
        presenceUsers: [
          {'user_id': 'user-a'},
          {'user_id': 'user-b'},
        ],
      );
      await Future<void>.delayed(Duration.zero);

      // Presence keeps firing while the roster read is in flight; the same
      // lobby listener re-applies it on every event.
      notifier.updateMembersFromPresence([
        {'user_id': 'user-a', 'has_book': true},
        {'user_id': 'user-b'},
      ]);
      delayedMembers.complete([
        testMember(roomId: 'room-a'),
        testMember(roomId: 'room-a', id: 'member-b', userId: 'user-b', nickname: 'Bob'),
      ]);
      await refresh;

      expect(
        notifier.state.members.map((member) => member.userId),
        ['user-a', 'user-b'],
      );
      expect(notifier.state.members.every((member) => member.isOnline), isTrue);
      expect(notifier.state.members.first.hasBook, isTrue);
    });

    test('a superseded roster read is discarded by the newer one', () async {
      final service = FakeRoomService()..members = [testMember(roomId: 'room-a')];
      final notifier = RoomNotifier(service);
      addTearDown(notifier.dispose);

      await notifier.createRoom('Alice');
      final stale = Completer<List<RoomMember>>();
      service.memberRead = stale;
      final staleRefresh = notifier.refreshMembers();
      await Future<void>.delayed(Duration.zero);

      service.memberRead = null;
      service.members = [
        testMember(roomId: 'room-a'),
        testMember(roomId: 'room-a', id: 'member-b', userId: 'user-b', nickname: 'Bob'),
      ];
      await notifier.refreshMembers();
      stale.complete([testMember(roomId: 'room-a')]);
      await staleRefresh;

      expect(notifier.state.members, hasLength(2));
    });

    test('a failing newer roster read keeps an older success', () async {
      final service = FakeRoomService()..members = [testMember(roomId: 'room-a')];
      final notifier = RoomNotifier(service);
      addTearDown(notifier.dispose);

      await notifier.createRoom('Alice');

      // Presence and membership_changed both refresh for the same join.
      final firstRead = Completer<List<RoomMember>>();
      service.memberRead = firstRead;
      final first = notifier.refreshMembers();
      await Future<void>.delayed(Duration.zero);

      final secondRead = Completer<List<RoomMember>>();
      service.memberRead = secondRead;
      final second = notifier.refreshMembers();
      await Future<void>.delayed(Duration.zero);

      firstRead.complete([
        testMember(roomId: 'room-a'),
        testMember(roomId: 'room-a', id: 'member-b', userId: 'user-b', nickname: 'Bob'),
      ]);
      secondRead.completeError(StateError('network failure'));
      await first;
      await second;

      // Losing the only usable answer would leave Start Reading disabled.
      expect(notifier.state.members, hasLength(2));
    });

    test('losing the room channel marks every member offline', () async {
      final service = FakeRoomService()..members = [testMember(roomId: 'room-a')];
      final notifier = RoomNotifier(service);
      addTearDown(notifier.dispose);

      await notifier.createRoom('Alice');
      notifier.updateMembersFromPresence([
        {'user_id': 'user-a', 'has_book': true},
      ]);
      expect(notifier.state.members.single.isOnline, isTrue);

      // PresenceNotifier clears onlineUsers on disconnect; an empty overlay is
      // an answer, not a gap, and the roster refresh that would otherwise fix
      // this needs the network that just went away.
      notifier.updateMembersFromPresence(const []);

      expect(notifier.state.members.single.isOnline, isFalse);
      expect(notifier.state.members.single.hasBook, isTrue);
    });

    test('presence with no roster change does not churn state', () async {
      final service = FakeRoomService()..members = [testMember(roomId: 'room-a')];
      final notifier = RoomNotifier(service);
      addTearDown(notifier.dispose);

      await notifier.createRoom('Alice');
      notifier.updateMembersFromPresence([
        {'user_id': 'user-a'},
      ]);
      final settled = notifier.state.members;
      notifier.updateMembersFromPresence([
        {'user_id': 'user-a'},
      ]);

      expect(identical(notifier.state.members, settled), isTrue);
    });

    test('a delayed room refresh cannot resurrect a previous session', () async {
      final service = FakeRoomService();
      final notifier = RoomNotifier(service);
      addTearDown(notifier.dispose);

      final roomA = await notifier.createRoom('Alice');
      final delayedRoom = Completer<Room?>();
      service.roomRead = delayedRoom;
      final refresh = notifier.refreshRoom();
      await Future<void>.delayed(Duration.zero);

      await notifier.leaveRoom();
      service.roomRead = null;
      service.nextRoom = testRoom(id: 'room-b', code: 'BBBBBB');
      await notifier.createRoom('Alice');
      delayedRoom.complete(roomA!.copyWith(currentCfi: 'epubcfi(/6/18)'));
      await refresh;

      expect(notifier.state.currentRoom?.id, 'room-b');
      expect(notifier.state.currentRoom?.currentCfi, isNull);
    });

    test('a delayed room snapshot cannot overwrite a newer local event', () async {
      final service = FakeRoomService();
      final notifier = RoomNotifier(service);
      addTearDown(notifier.dispose);

      final room = await notifier.createRoom('Alice');
      final delayedRoom = Completer<Room?>();
      service.roomRead = delayedRoom;
      final refresh = notifier.refreshRoom();
      await Future<void>.delayed(Duration.zero);

      notifier.onBookSharedReceived(
        bookTitle: 'New book',
        bookHash: List.filled(64, 'a').join(),
      );
      delayedRoom.complete(room);
      await refresh;

      expect(notifier.state.currentRoom?.currentBookTitle, 'New book');
      expect(
        notifier.state.currentRoom?.currentBookHash,
        List.filled(64, 'a').join(),
      );
    });

    test('authoritative refresh returns the applied room snapshot', () async {
      final service = FakeRoomService();
      final notifier = RoomNotifier(service);
      addTearDown(notifier.dispose);

      final room = await notifier.createRoom('Alice');
      service.nextRoom = room!.copyWith(
        currentCfi: 'epubcfi(/6/20)',
        revision: 1,
      );

      final refreshed = await notifier.refreshRoomAndGet();

      expect(refreshed?.currentCfi, 'epubcfi(/6/20)');
      expect(refreshed?.revision, 1);
      expect(notifier.state.currentRoom, same(refreshed));
    });

    test('missing authoritative room snapshot revokes the session', () async {
      final missingRoom = Completer<Room?>()..complete(null);
      final service = FakeRoomService()..roomRead = missingRoom;
      var teardownCalls = 0;
      final notifier = RoomNotifier(
        service,
        onSessionRevoked: () async {
          teardownCalls++;
        },
      );
      addTearDown(notifier.dispose);

      await notifier.createRoom('Alice');
      final refreshed = await notifier.refreshRoomAndGet();

      expect(refreshed, isNull);
      expect(notifier.state.currentRoom, isNull);
      expect(notifier.state.error, contains('inactive'));
      expect(teardownCalls, 1);
    });

    test('CFI write refreshes and retries one room revision conflict', () async {
      final service = FakeRoomService()
        ..cfiConflicts = 1
        ..conflictRoom = testRoom(revision: 4);
      final notifier = RoomNotifier(service);
      addTearDown(notifier.dispose);

      final room = await notifier.createRoom('Alice');
      await notifier.updateCfiForRoom(
        roomId: room!.id,
        cfi: 'epubcfi(/6/22)',
      );

      expect(service.cfiExpectedRevisions, [0, 4]);
      expect(notifier.state.currentRoom?.revision, 5);
      expect(notifier.state.currentRoom?.currentCfi, 'epubcfi(/6/22)');
    });

    test('book share refreshes and retries one room revision conflict', () async {
      final service = FakeRoomService()
        ..bookConflicts = 1
        ..conflictRoom = testRoom(revision: 7);
      final notifier = RoomNotifier(service);
      addTearDown(notifier.dispose);

      await notifier.createRoom('Alice');
      final bookHash = List.filled(64, 'b').join();
      await notifier.updateBookShared(
        bookTitle: 'Concurrent Book',
        bookHash: bookHash,
      );

      expect(service.bookExpectedRevisions, [0, 7]);
      expect(notifier.state.currentRoom?.revision, 8);
      expect(notifier.state.currentRoom?.currentBookHash, bookHash);
    });

    test('a book someone else shared first is not overwritten on the retry', () async {
      // Regression: the conflict retry took the newer revision and wrote over
      // the book another member had just shared.
      final otherBook = List.filled(64, 'c').join();
      final service = FakeRoomService()
        ..bookConflicts = 1
        ..conflictRoom = testRoom(
          revision: 7,
        ).copyWith(currentBookTitle: 'Bob', currentBookHash: otherBook);
      final notifier = RoomNotifier(service);
      addTearDown(notifier.dispose);

      await notifier.createRoom('Alice');
      final isRoomBook = await notifier.updateBookShared(
        bookTitle: 'Alice',
        bookHash: List.filled(64, 'b').join(),
      );

      expect(isRoomBook, isFalse);
      expect(service.bookExpectedRevisions, [0]);
      expect(notifier.state.currentRoom?.currentBookHash, otherBook);
    });

    test('a library book is recorded in the room with its library path', () async {
      // GH-28: members who open the lobby after the share only see the room
      // row, so the path has to be stored there, not just broadcast.
      final service = FakeRoomService();
      final notifier = RoomNotifier(service);
      addTearDown(notifier.dispose);

      await notifier.createRoom('Alice');
      await notifier.updateBookShared(
        bookTitle: 'Moby-Dick',
        bookHash: List.filled(64, 'b').join(),
        libraryPath: 'classics/moby-dick.epub',
      );
      expect(
        notifier.state.currentRoom?.currentBookLibraryPath,
        'classics/moby-dick.epub',
      );

      // A book from this device replaces the path instead of inheriting it.
      await notifier.updateBookShared(
        bookTitle: 'Notes',
        bookHash: List.filled(64, 'c').join(),
      );
      expect(service.bookLibraryPaths, ['classics/moby-dick.epub', null]);
      expect(notifier.state.currentRoom?.currentBookLibraryPath, isNull);
    });

    test('a shared book announcement replaces the previous library path', () async {
      final service = FakeRoomService()
        ..nextRoom = testRoom().copyWith(
          currentBookHash: List.filled(64, 'a').join(),
          currentBookLibraryPath: 'classics/old.epub',
        );
      final notifier = RoomNotifier(service);
      addTearDown(notifier.dispose);

      await notifier.createRoom('Alice');
      notifier.onBookSharedReceived(
        bookTitle: 'Local book',
        bookHash: List.filled(64, 'b').join(),
      );

      expect(notifier.state.currentRoom?.currentBookLibraryPath, isNull);
    });
  });

  // GH-30: copyWith used to drop the error on every update, so a message
  // vanished whenever some unrelated update ran, and code that needed one to
  // survive had to copy it across by hand.
  group('room errors', () {
    test('stay up through Presence and book updates that fix nothing', () async {
      final service = FakeRoomService()..members = [testMember(roomId: 'room-a')];
      final notifier = RoomNotifier(service);
      addTearDown(notifier.dispose);

      await notifier.createRoom('Alice');
      service.heartbeatError = StateError('temporary network failure');
      await expectLater(notifier.heartbeat(), throwsStateError);

      notifier.updateMembersFromPresence([
        {'user_id': 'user-a', 'has_book': true},
      ]);
      notifier.onBookSharedReceived(bookTitle: 'Moby-Dick', bookHash: 'hash');

      expect(notifier.state.members.single.isOnline, isTrue);
      expect(notifier.state.currentRoom?.currentBookTitle, 'Moby-Dick');
      expect(notifier.state.error, contains('temporary network failure'));
    });

    test('a successful heartbeat clears the error', () async {
      final service = FakeRoomService();
      final notifier = RoomNotifier(service);
      addTearDown(notifier.dispose);

      await notifier.createRoom('Alice');
      service.heartbeatError = StateError('temporary network failure');
      await expectLater(notifier.heartbeat(), throwsStateError);
      service
        ..heartbeatError = null
        ..nextRoom = testRoom(revision: 1);
      await notifier.heartbeat();

      expect(notifier.state.error, isNull);
    });

    test('a roster read that gets through clears a failed one', () async {
      final service = FakeRoomService()..members = [testMember(roomId: 'room-a')];
      final notifier = RoomNotifier(service);
      addTearDown(notifier.dispose);

      await notifier.createRoom('Alice');
      service.memberRead = Completer()..completeError(StateError('offline'));
      await notifier.refreshMembers();
      expect(notifier.state.error, contains('offline'));

      service.memberRead = null;
      await notifier.refreshMembers();
      expect(notifier.state.error, isNull);
    });

    test('a failed join is cleared by the next room entered', () async {
      final service = FakeRoomService()
        ..joinError = const RoomNotFoundException('ZZZZZZ');
      final notifier = RoomNotifier(service);
      addTearDown(notifier.dispose);

      await notifier.joinRoom('ZZZZZZ', 'Alice');
      expect(notifier.state.error, isNotNull);

      expect(await notifier.createRoom('Alice'), isNotNull);
      expect(notifier.state.error, isNull);
    });

    test('a revoked session stays explained until dismissed', () async {
      final service = FakeRoomService();
      final notifier = RoomNotifier(service);
      addTearDown(notifier.dispose);

      await notifier.createRoom('Alice');
      service.heartbeatError = const RoomSessionRevokedException(
        'membership expired',
      );
      await expectLater(
        notifier.heartbeat(),
        throwsA(isA<RoomSessionRevokedException>()),
      );
      expect(notifier.state.error, 'membership expired');

      notifier.clearError();
      expect(notifier.state.error, isNull);
    });
  });
}

Room testRoom({
  String id = 'room-a',
  String code = 'AAAAAA',
  int revision = 0,
}) {
  final now = DateTime.utc(2026, 8, 12);
  return Room(
    id: id,
    code: code,
    hostUserId: 'user-a',
    revision: revision,
    createdAt: now,
    updatedAt: now,
  );
}

RoomMember testMember({
  required String roomId,
  String id = 'member-a',
  String userId = 'user-a',
  String nickname = 'Alice',
}) {
  return RoomMember(
    id: id,
    roomId: roomId,
    userId: userId,
    nickname: nickname,
    joinedAt: DateTime.utc(2026, 8, 12),
  );
}

class FakeRoomService extends RoomService {
  Room nextRoom = testRoom();
  Object? heartbeatError;
  Completer<Room>? heartbeatReply;
  Object? cfiError;
  Object? bookError;
  Completer<Room>? cfiWrite;
  Completer<List<RoomMember>>? memberRead;
  Completer<Room?>? roomRead;
  int? lastCfiExpectedRevision;
  List<RoomMember> members = const [];
  int cfiConflicts = 0;
  int bookConflicts = 0;
  Room conflictRoom = testRoom();
  final List<int> cfiExpectedRevisions = [];
  final List<int> bookExpectedRevisions = [];
  final List<String?> bookLibraryPaths = [];
  final List<String> cfiWrites = [];

  Object? joinError;
  final List<String> joinedCodes = [];
  int createCalls = 0;

  /// Null answers every code as available.
  Set<String>? availableCodes;
  Object? availabilityError;

  @override
  Future<Room> createRoom({required String nickname}) async {
    createCalls++;
    return nextRoom;
  }

  @override
  Future<Set<String>> availableRoomCodes(List<String> codes) async {
    final error = availabilityError;
    if (error != null) throw error;
    final available = availableCodes;
    return available == null
        ? codes.toSet()
        : codes.where(available.contains).toSet();
  }

  @override
  Future<Room> joinRoom({
    required String code,
    required String nickname,
  }) async {
    joinedCodes.add(code);
    final error = joinError;
    if (error != null) throw error;
    return nextRoom;
  }

  @override
  Future<List<RoomMember>> getRoomMembers(String roomId) async {
    return memberRead?.future ?? members;
  }

  @override
  Future<Room?> getRoom(String roomId) async {
    roomReads++;
    final error = roomReadError;
    if (error != null) throw error;
    return roomRead?.future ?? nextRoom;
  }

  int roomReads = 0;
  Object? roomReadError;
  Object? textSizeError;
  final List<(bool, int?)> textSizeWrites = [];

  @override
  Future<Room> setRoomTextSize({
    required String roomId,
    required bool locked,
    int? textSize,
  }) async {
    textSizeWrites.add((locked, textSize));
    final error = textSizeError;
    if (error != null) throw error;
    nextRoom = nextRoom.copyWith(
      textSizeLocked: locked,
      textSize: textSize ?? nextRoom.textSize,
      revision: nextRoom.revision + 1,
    );
    return nextRoom;
  }

  @override
  Future<Room> heartbeatRoom(String roomId) async {
    final reply = heartbeatReply;
    if (reply != null) return reply.future;
    final error = heartbeatError;
    if (error != null) throw error;
    return nextRoom;
  }

  @override
  Future<Room> updateRoomCfi({
    required String roomId,
    required String cfi,
    required int expectedRevision,
  }) async {
    lastCfiExpectedRevision = expectedRevision;
    cfiWrites.add(cfi);
    cfiExpectedRevisions.add(expectedRevision);
    if (cfiConflicts > 0) {
      cfiConflicts--;
      throw RoomRevisionConflictException(conflictRoom);
    }
    final error = cfiError;
    if (error != null) throw error;
    final pending = cfiWrite;
    if (pending != null) return pending.future;
    return nextRoom.copyWith(
      currentCfi: cfi,
      revision: expectedRevision + 1,
    );
  }

  @override
  Future<Room> updateRoomBook({
    required String roomId,
    required String bookTitle,
    required String bookHash,
    required int expectedRevision,
    String? libraryPath,
  }) async {
    bookExpectedRevisions.add(expectedRevision);
    bookLibraryPaths.add(libraryPath);
    final error = bookError;
    if (error != null) throw error;
    if (bookConflicts > 0) {
      bookConflicts--;
      throw RoomRevisionConflictException(conflictRoom);
    }
    return nextRoom.copyWith(
      currentBookTitle: bookTitle,
      currentBookHash: bookHash,
      currentBookLibraryPath: libraryPath,
      revision: expectedRevision + 1,
    );
  }

  int leaveFailures = 0;
  int leaveCalls = 0;
  Completer<void>? leaveReply;

  @override
  Future<Map<String, dynamic>> leaveRoom({required String roomId}) async {
    leaveCalls++;
    final reply = leaveReply;
    if (reply != null) await reply.future;
    if (leaveFailures > 0) {
      leaveFailures--;
      throw StateError('connection reset');
    }
    return {'left': true};
  }
}
