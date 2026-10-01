import 'dart:async';

import 'package:cotime_book/models/room.dart';
import 'package:cotime_book/models/room_member.dart';
import 'package:cotime_book/providers/room_provider.dart';
import 'package:cotime_book/services/room_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('RoomNotifier', () {
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

      final room = await notifier.rejoinRoom('ABC234', 'Alice');

      expect(room?.code, 'ABC234');
      expect(service.createCalls, 0);
      expect(notifier.state.currentRoom?.code, 'ABC234');
    });

    test('a recent room that has closed opens a new room instead', () async {
      // Codes are never reused, so the old room can't come back; tapping it
      // must still leave the person in a room rather than on an error.
      final service = FakeRoomService()
        ..joinError = const RoomNotFoundException('ABC234')
        ..createdRoom = testRoom(id: 'room-b', code: 'XYZ789');
      final notifier = RoomNotifier(service);
      addTearDown(notifier.dispose);

      final room = await notifier.rejoinRoom('ABC234', 'Alice');

      expect(service.joinedCodes, ['ABC234']);
      expect(room?.code, 'XYZ789');
      expect(notifier.state.currentRoom?.code, 'XYZ789');
      expect(notifier.state.error, isNull);
    });

    test('joining a closed room by code says so in words', () async {
      final service = FakeRoomService()
        ..joinError = const RoomNotFoundException('ABC234');
      final notifier = RoomNotifier(service);
      addTearDown(notifier.dispose);

      expect(await notifier.joinRoom('ABC234', 'Alice'), isNull);
      expect(service.createCalls, 0);
      expect(notifier.state.error, 'Room ABC234 has closed or does not exist.');
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
  final List<String> cfiWrites = [];

  Object? joinError;
  Room? createdRoom;
  final List<String> joinedCodes = [];
  int createCalls = 0;

  @override
  Future<Room> createRoom({required String nickname}) async {
    createCalls++;
    return createdRoom ?? nextRoom;
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
    return roomRead?.future ?? nextRoom;
  }

  @override
  Future<Room> heartbeatRoom(String roomId) async {
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
  }) async {
    bookExpectedRevisions.add(expectedRevision);
    final error = bookError;
    if (error != null) throw error;
    if (bookConflicts > 0) {
      bookConflicts--;
      throw RoomRevisionConflictException(conflictRoom);
    }
    return nextRoom.copyWith(
      currentBookTitle: bookTitle,
      currentBookHash: bookHash,
      revision: expectedRevision + 1,
    );
  }

  int leaveFailures = 0;
  int leaveCalls = 0;

  @override
  Future<Map<String, dynamic>> leaveRoom({required String roomId}) async {
    leaveCalls++;
    if (leaveFailures > 0) {
      leaveFailures--;
      throw StateError('connection reset');
    }
    return {'left': true};
  }
}
