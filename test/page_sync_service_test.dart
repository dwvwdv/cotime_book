import 'dart:async';

import 'package:cotime_book/models/page_sync_state.dart';
import 'package:cotime_book/services/page_sync_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('PageSyncService', () {
    test('readers on different screens keep turning pages together', () async {
      // Regression: the old protocol required every reader's CFI string to be
      // identical. Two different screens paginate differently, so their CFIs
      // for the same page never matched and every turn was rejected — the
      // room stayed on page one.
      final room = FakeRoom();
      final alice = room.join('alice', 'Alice', layout: 'phone');
      final bob = room.join('bob', 'Bob', layout: 'tablet');
      addTearDown(room.dispose);
      await flush();

      for (var turn = 1; turn <= 4; turn++) {
        final requester = turn.isOdd ? alice : bob;
        final follower = turn.isOdd ? bob : alice;

        expect(
          await requester.service.requestPageTurn(
            direction: PageTurnDirection.next,
          ),
          isTrue,
          reason: 'turn $turn request',
        );
        await flush();
        expect(follower.service.currentState.status, SyncStatus.confirming);
        await follower.service.confirmPageTurn();
        await flush();

        expect(alice.service.position.seq, turn, reason: 'alice turn $turn');
        expect(bob.service.position.seq, turn, reason: 'bob turn $turn');
        expect(alice.service.position, bob.service.position);
        expect(alice.service.currentState.status, SyncStatus.idle);
        expect(bob.service.currentState.status, SyncStatus.idle);
        expect(alice.service.currentState.errorMessage, isNull);
        expect(bob.service.currentState.errorMessage, isNull);
      }
      // The follower was told to display each page the requester landed on.
      expect(bob.displayed.length, 2);
      expect(alice.displayed.length, 2);
    });

    test('a reader reading alone turns without asking anyone', () async {
      final room = FakeRoom();
      final alice = room.join('alice', 'Alice');
      room.join('carol', 'Carol', isReading: false); // still in the lobby
      addTearDown(room.dispose);
      await flush();

      expect(
        await alice.service.requestPageTurn(direction: PageTurnDirection.next),
        isTrue,
      );
      await flush();

      expect(alice.service.position.seq, 1);
      expect(
        room.sent.where((e) => e.event == PageSyncService.requestEvent),
        isEmpty,
      );
    });

    test('someone in the lobby or still loading never blocks a turn', () async {
      final room = FakeRoom();
      final alice = room.join('alice', 'Alice');
      final bob = room.join('bob', 'Bob');
      room.join('carol', 'Carol', isReading: false);
      room.join('dave', 'Dave', readerReady: false);
      addTearDown(room.dispose);
      await flush();

      await alice.service.requestPageTurn(direction: PageTurnDirection.next);
      await flush();
      expect(alice.service.currentState.currentRequest!.requiredUserIds, {
        'alice',
        'bob',
      });
      await bob.service.confirmPageTurn();
      await flush();

      expect(alice.service.position.seq, 1);
      expect(bob.service.position.seq, 1);
    });

    test(
      'a reader who opens the book late lands on the room\'s page',
      () async {
        final room = FakeRoom();
        final alice = room.join('alice', 'Alice');
        addTearDown(room.dispose);
        await flush();
        for (var i = 0; i < 3; i++) {
          await alice.service.requestPageTurn(
            direction: PageTurnDirection.next,
          );
          await flush();
        }
        expect(alice.service.position.seq, 3);

        // Bob starts from the database, which may be behind.
        final bob = room.join(
          'bob',
          'Bob',
          initialPosition: const SharedPosition(seq: 0, cfi: 'db-cfi'),
        );
        await flush();

        expect(bob.service.position, alice.service.position);
        expect(bob.displayed, [alice.service.position]);
      },
    );

    test('a lost commit still reaches the follower through Presence', () async {
      final room = FakeRoom();
      final alice = room.join('alice', 'Alice');
      final bob = room.join('bob', 'Bob');
      addTearDown(room.dispose);
      await flush();

      room.dropEvents.add(PageSyncService.commitEvent);
      await alice.service.requestPageTurn(direction: PageTurnDirection.next);
      await flush();
      await bob.service.confirmPageTurn();
      await flush();

      expect(alice.service.position.seq, 1);
      expect(bob.service.position, alice.service.position);
      expect(bob.service.currentState.status, SyncStatus.idle);
    });

    test('a lost vote is sent again when the requester nudges', () async {
      final room = FakeRoom();
      final alice = room.join(
        'alice',
        'Alice',
        nudgeInterval: const Duration(milliseconds: 20),
      );
      final bob = room.join('bob', 'Bob');
      addTearDown(room.dispose);
      await flush();

      await alice.service.requestPageTurn(direction: PageTurnDirection.next);
      await flush();
      room.dropEvents.add(PageSyncService.voteEvent);
      await bob.service.confirmPageTurn();
      await flush();
      expect(alice.service.position.seq, 0);

      room.dropEvents.clear();
      await Future<void>.delayed(const Duration(milliseconds: 60));
      await flush();

      expect(alice.service.position.seq, 1);
      expect(bob.service.position.seq, 1);
    });

    test(
      'a follower that missed the request picks it up from a nudge',
      () async {
        final room = FakeRoom();
        final alice = room.join(
          'alice',
          'Alice',
          nudgeInterval: const Duration(milliseconds: 20),
        );
        final bob = room.join('bob', 'Bob');
        addTearDown(room.dispose);
        await flush();

        room.dropEvents.add(PageSyncService.requestEvent);
        await alice.service.requestPageTurn(direction: PageTurnDirection.next);
        await flush();
        expect(bob.service.currentState.status, SyncStatus.idle);

        room.dropEvents.clear();
        await Future<void>.delayed(const Duration(milliseconds: 60));
        await flush();
        expect(bob.service.currentState.status, SyncStatus.confirming);
      },
    );

    test('declining names the reader and releases everyone', () async {
      final room = FakeRoom();
      final alice = room.join('alice', 'Alice');
      final bob = room.join('bob', 'Bob');
      addTearDown(room.dispose);
      await flush();

      await alice.service.requestPageTurn(direction: PageTurnDirection.next);
      await flush();
      await bob.service.declinePageTurn();
      await flush();

      expect(alice.service.currentState.status, SyncStatus.idle);
      expect(alice.service.currentState.currentRequest, isNull);
      expect(
        alice.service.currentState.errorMessage,
        'Bob asked to wait on this page',
      );
      expect(bob.service.currentState.status, SyncStatus.idle);
      expect(alice.service.position.seq, 0);
    });

    test('a reader who leaves the book stops blocking the turn', () async {
      final room = FakeRoom();
      final alice = room.join('alice', 'Alice');
      final bob = room.join('bob', 'Bob');
      room.join('carol', 'Carol');
      addTearDown(room.dispose);
      await flush();

      await alice.service.requestPageTurn(direction: PageTurnDirection.next);
      await flush();
      await bob.service.confirmPageTurn();
      await flush();
      expect(alice.service.position.seq, 0, reason: 'still waiting for Carol');

      room.setPresence('carol', isReading: false);
      await flush();

      expect(alice.service.position.seq, 1);
      expect(bob.service.position.seq, 1);
    });

    test('a requester who leaves releases the readers it asked', () async {
      final room = FakeRoom();
      final alice = room.join('alice', 'Alice');
      final bob = room.join('bob', 'Bob');
      addTearDown(room.dispose);
      await flush();

      await alice.service.requestPageTurn(direction: PageTurnDirection.next);
      await flush();
      expect(bob.service.currentState.status, SyncStatus.confirming);

      room.leave('alice');
      await flush();

      expect(bob.service.currentState.status, SyncStatus.idle);
      expect(bob.service.currentState.errorMessage, 'Alice left the book');
    });

    test('a request whose requester went silent expires', () async {
      final room = FakeRoom();
      final alice = room.join('alice', 'Alice');
      final bob = room.join(
        'bob',
        'Bob',
        followerLiveness: const Duration(milliseconds: 40),
      );
      addTearDown(room.dispose);
      await flush();

      await alice.service.requestPageTurn(direction: PageTurnDirection.next);
      await flush();
      // Alice's app freezes: Presence still shows her, but nothing more is
      // sent.
      await alice.service.dispose();
      expect(bob.service.currentState.status, SyncStatus.confirming);

      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(bob.service.currentState.status, SyncStatus.idle);
      expect(bob.service.currentState.currentRequest, isNull);
    });

    test('two readers pressing next together turn exactly one page', () async {
      final room = FakeRoom();
      final alice = room.join('alice', 'Alice');
      final bob = room.join('bob', 'Bob');
      addTearDown(room.dispose);
      await flush();

      await Future.wait([
        alice.service.requestPageTurn(direction: PageTurnDirection.next),
        bob.service.requestPageTurn(direction: PageTurnDirection.next),
      ]);
      await flush();
      await flush();

      expect(alice.service.position.seq, 1);
      expect(bob.service.position, alice.service.position);
      expect(alice.service.currentState.status, SyncStatus.idle);
      expect(bob.service.currentState.status, SyncStatus.idle);
      expect(room.turnsExecuted, 1);
    });

    test('a request from a page the room has left is refused', () async {
      final room = FakeRoom();
      final alice = room.join(
        'alice',
        'Alice',
        initialPosition: const SharedPosition(seq: 4, cfi: 'p4'),
      );
      addTearDown(room.dispose);
      await flush();

      room.inject(PageSyncService.requestEvent, {
        'request_id': 'old',
        'user_id': 'bob',
        'nickname': 'Bob',
        'direction': 'next',
        'from_seq': 2,
        'requested_at': DateTime.now().toUtc().toIso8601String(),
        'required_users': ['alice', 'bob'],
      });
      await flush();

      expect(alice.service.currentState.status, SyncStatus.idle);
      final vote = room.sent.singleWhere(
        (e) => e.event == PageSyncService.voteEvent,
      );
      expect(vote.payload['accept'], isFalse);
      expect(vote.payload['reason'], 'out_of_sync');
    });

    test('a requester that is behind is told so in plain words', () async {
      final room = FakeRoom();
      final alice = room.join('alice', 'Alice');
      room.join('bob', 'Bob');
      addTearDown(room.dispose);
      await flush();
      room.dropEvents.add(PageSyncService.requestEvent);

      await alice.service.requestPageTurn(direction: PageTurnDirection.next);
      final requestId = alice.service.currentState.currentRequest!.requestId;
      room.inject(PageSyncService.voteEvent, {
        'request_id': requestId,
        'user_id': 'bob',
        'accept': false,
        'reason': 'out_of_sync',
      });
      await flush();

      expect(alice.service.currentState.status, SyncStatus.idle);
      expect(alice.service.currentState.errorMessage, isNot(contains('_')));
      expect(
        alice.service.currentState.errorMessage,
        contains('different pages'),
      );
    });

    test('a turn that cannot move releases everyone', () async {
      final room = FakeRoom();
      final alice = room.join('alice', 'Alice', canTurn: false);
      final bob = room.join('bob', 'Bob');
      addTearDown(room.dispose);
      await flush();

      await alice.service.requestPageTurn(
        direction: PageTurnDirection.previous,
      );
      await flush();
      await bob.service.confirmPageTurn();
      await flush();

      expect(alice.service.position.seq, 0);
      expect(alice.service.currentState.status, SyncStatus.idle);
      expect(alice.service.currentState.errorMessage, contains('did not move'));
      expect(bob.service.currentState.status, SyncStatus.idle);
      expect(bob.service.currentState.currentRequest, isNull);
    });

    test('a turn the viewer never finishes times out', () async {
      final room = FakeRoom();
      final alice = room.join(
        'alice',
        'Alice',
        neverRelocates: true,
        turnTimeout: const Duration(milliseconds: 30),
      );
      addTearDown(room.dispose);
      await flush();

      await alice.service.requestPageTurn(direction: PageTurnDirection.next);
      expect(alice.service.currentState.status, SyncStatus.turning);
      await Future<void>.delayed(const Duration(milliseconds: 60));

      expect(alice.service.currentState.status, SyncStatus.idle);
      expect(alice.abandoned, hasLength(1));
    });

    test(
      'an unanswered request times out and names who it waited for',
      () async {
        final room = FakeRoom();
        final alice = room.join(
          'alice',
          'Alice',
          requestTimeout: const Duration(milliseconds: 40),
        );
        room.join('bob', 'Bob');
        addTearDown(room.dispose);
        await flush();

        await alice.service.requestPageTurn(direction: PageTurnDirection.next);
        await Future<void>.delayed(const Duration(milliseconds: 80));

        expect(alice.service.currentState.status, SyncStatus.idle);
        expect(
          alice.service.currentState.errorMessage,
          'Page turn timed out waiting for Bob',
        );
      },
    );

    test(
      'a transient failure clears itself instead of pinning the bar',
      () async {
        final room = FakeRoom();
        final alice = room.join(
          'alice',
          'Alice',
          errorAutoClearDelay: const Duration(milliseconds: 20),
        );
        final bob = room.join('bob', 'Bob');
        addTearDown(room.dispose);
        await flush();

        await alice.service.requestPageTurn(direction: PageTurnDirection.next);
        await flush();
        await bob.service.declinePageTurn();
        await flush();
        expect(alice.service.currentState.errorMessage, isNotNull);

        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(alice.service.currentState.errorMessage, isNull);
        expect(alice.service.currentState.status, SyncStatus.idle);
      },
    );

    test('fails closed until Presence includes this reader', () async {
      final room = FakeRoom();
      final alice = room.join('alice', 'Alice', trackPresence: false);
      addTearDown(room.dispose);
      await flush();

      expect(
        await alice.service.requestPageTurn(direction: PageTurnDirection.next),
        isFalse,
      );
      expect(alice.service.currentState.errorMessage, contains('connecting'));
      expect(alice.service.position.seq, 0);
    });

    test(
      'a dropped connection does not let the requester turn alone',
      () async {
        final room = FakeRoom();
        final alice = room.join('alice', 'Alice');
        room.join('bob', 'Bob');
        addTearDown(room.dispose);
        await flush();

        await alice.service.requestPageTurn(direction: PageTurnDirection.next);
        await flush();
        // A reconnect empties the Presence view for a moment.
        room.blackout('alice');
        await flush();

        expect(alice.service.position.seq, 0);
        expect(alice.service.currentState.status, SyncStatus.requesting);
        expect(alice.service.currentState.currentRequest!.requiredUserIds, {
          'alice',
          'bob',
        });
      },
    );

    test('a loading reader cannot start a turn', () async {
      final room = FakeRoom();
      final alice = room.join('alice', 'Alice', viewerReady: false);
      addTearDown(room.dispose);
      await flush();

      expect(
        await alice.service.requestPageTurn(direction: PageTurnDirection.next),
        isFalse,
      );
      expect(alice.service.currentState.errorMessage, contains('loading'));
    });

    test('readers converge on one page after conflicting commits', () async {
      final room = FakeRoom();
      final alice = room.join(
        'alice',
        'Alice',
        initialPosition: const SharedPosition(seq: 2, cfi: 'aaa'),
      );
      final bob = room.join(
        'bob',
        'Bob',
        initialPosition: const SharedPosition(seq: 2, cfi: 'bbb'),
      );
      addTearDown(room.dispose);
      await flush();

      expect(alice.service.position, const SharedPosition(seq: 2, cfi: 'bbb'));
      expect(bob.service.position, const SharedPosition(seq: 2, cfi: 'bbb'));
    });
  });

  test('cancel reasons are never shown as protocol codes', () {
    for (final reason in [
      'timeout',
      'out_of_sync',
      'requester_left',
      'superseded',
      'turn_failed',
      'declined_by_Bob',
      'something_new',
    ]) {
      expect(
        describeCancelReason(reason),
        isNot(contains('_')),
        reason: reason,
      );
    }
    expect(
      describeCancelReason('declined_by_Bob'),
      'Bob asked to wait on this page',
    );
  });
}

Future<void> flush() async {
  for (var i = 0; i < 6; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

class SentEvent {
  final String sender;
  final String event;
  final Map<String, dynamic> payload;

  const SentEvent(this.sender, this.event, this.payload);
}

/// A room of readers wired through one fake Realtime channel: broadcasts reach
/// everyone (sender included, as with `self: true`), and every client sees the
/// same Presence.
class FakeRoom {
  final Map<String, FakeReader> readers = {};
  final Map<String, Map<String, dynamic>> _presence = {};
  final Set<String> _blackedOut = {};
  final List<SentEvent> sent = [];
  final Set<String> dropEvents = {};
  int turnsExecuted = 0;

  FakeReader join(
    String userId,
    String nickname, {
    bool isReading = true,
    bool readerReady = true,
    bool viewerReady = true,
    bool trackPresence = true,
    bool canTurn = true,
    bool neverRelocates = false,
    String layout = 'phone',
    SharedPosition initialPosition = const SharedPosition.start(),
    Duration requestTimeout = const Duration(minutes: 5),
    Duration nudgeInterval = const Duration(minutes: 5),
    Duration followerLiveness = const Duration(minutes: 5),
    Duration turnTimeout = const Duration(minutes: 5),
    Duration errorAutoClearDelay = const Duration(hours: 1),
  }) {
    if (trackPresence) {
      _presence[userId] = {
        'user_id': userId,
        'nickname': nickname,
        'is_reading': isReading,
        'reader_ready': readerReady,
      };
    }
    final transport = FakeTransport(this, userId);
    final service = PageSyncService(
      transport: transport,
      currentUserId: userId,
      currentNickname: nickname,
      initialPosition: initialPosition,
      requestTimeout: requestTimeout,
      nudgeInterval: nudgeInterval,
      followerLiveness: followerLiveness,
      turnTimeout: turnTimeout,
      errorAutoClearDelay: errorAutoClearDelay,
    );
    final reader = FakeReader(service, transport);
    var localPage = 0;
    service.onExecuteTurn = (command) {
      turnsExecuted++;
      if (neverRelocates) return;
      scheduleMicrotask(() {
        if (!canTurn) {
          service.abandonTurn(command.requestId);
          return;
        }
        localPage += command.direction == PageTurnDirection.next ? 1 : -1;
        // Each device paginates its own way: the CFI it lands on is its own.
        service.completeTurn(command.requestId, 'cfi-$layout-$localPage');
      });
    };
    service.onPositionChanged = reader.displayed.add;
    service.onTurnAbandoned = reader.abandoned.add;
    service.setViewerReady(viewerReady && isReading);
    readers[userId] = reader;
    service.initialize();
    if (trackPresence) _emitPresence();
    return reader;
  }

  void setPresence(String userId, {bool? isReading, bool? readerReady}) {
    final meta = _presence[userId]!;
    if (isReading != null) meta['is_reading'] = isReading;
    if (readerReady != null) meta['reader_ready'] = readerReady;
    _emitPresence();
  }

  void publishPosition(String userId, SharedPosition position) {
    final meta = _presence[userId];
    if (meta == null) return;
    meta['page_seq'] = position.seq;
    meta['page_cfi'] = position.cfi;
    _emitPresence();
  }

  void leave(String userId) {
    _presence.remove(userId);
    _emitPresence();
  }

  /// This client's view of Presence goes empty, as during a reconnect.
  void blackout(String userId) {
    _blackedOut.add(userId);
    readers[userId]!.transport.presence.add({'event': 'sync'});
  }

  List<Map<String, dynamic>> presenceFor(String userId) {
    if (_blackedOut.contains(userId)) return const [];
    return [for (final meta in _presence.values) Map.of(meta)];
  }

  void deliver(String sender, String event, Map<String, dynamic> payload) {
    sent.add(SentEvent(sender, event, Map.of(payload)));
    if (dropEvents.contains(event)) return;
    for (final reader in readers.values.toList()) {
      final copy = Map<String, dynamic>.from(payload);
      scheduleMicrotask(() => reader.transport.receive(event, copy));
    }
  }

  /// A message from a client that is not modelled here.
  void inject(String event, Map<String, dynamic> payload) {
    for (final reader in readers.values) {
      reader.transport.receive(event, Map.of(payload));
    }
  }

  void _emitPresence() {
    for (final reader in readers.values.toList()) {
      scheduleMicrotask(() {
        if (!reader.transport.presence.isClosed) {
          reader.transport.presence.add({'event': 'sync'});
        }
      });
    }
  }

  Future<void> dispose() async {
    for (final reader in readers.values) {
      await reader.service.dispose();
      await reader.transport.close();
    }
  }
}

class FakeReader {
  final PageSyncService service;
  final FakeTransport transport;
  final List<SharedPosition> displayed = [];
  final List<String> abandoned = [];

  FakeReader(this.service, this.transport);
}

class FakeTransport implements PageSyncTransport {
  final FakeRoom room;
  final String userId;
  final Map<String, StreamController<Map<String, dynamic>>> _controllers = {};
  final presence = StreamController<Map<String, dynamic>>.broadcast();

  FakeTransport(this.room, this.userId);

  @override
  Stream<Map<String, dynamic>> broadcastStream(String event) {
    return (_controllers[event] ??=
            StreamController<Map<String, dynamic>>.broadcast())
        .stream;
  }

  @override
  Stream<Map<String, dynamic>> get presenceStream => presence.stream;

  @override
  List<Map<String, dynamic>> getOnlineUsers() => room.presenceFor(userId);

  @override
  Future<void> broadcast({
    required String event,
    required Map<String, dynamic> payload,
  }) async {
    room.deliver(userId, event, payload);
  }

  @override
  Future<void> publishPosition(SharedPosition position) async {
    room.publishPosition(userId, position);
  }

  void receive(String event, Map<String, dynamic> payload) {
    final controller = _controllers[event];
    if (controller != null && !controller.isClosed) controller.add(payload);
  }

  Future<void> close() async {
    await presence.close();
    for (final controller in _controllers.values) {
      await controller.close();
    }
  }
}
