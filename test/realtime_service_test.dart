import 'package:cotime_book/config/app_constants.dart';
import 'package:cotime_book/services/file_transfer_service.dart';
import 'package:cotime_book/services/page_sync_service.dart';
import 'package:cotime_book/services/peer_book_link.dart';
import 'package:cotime_book/services/realtime_service.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  late List<_FakeRoomChannel> channels;
  late RealtimeService service;

  setUp(() {
    channels = [];
    service = RealtimeService(
      channelFactory: (name, presenceKey) {
        final channel = _FakeRoomChannel(name, presenceKey);
        channels.add(channel);
        return channel;
      },
      presenceCoalesceDelay: Duration.zero,
    );
  });

  tearDown(() async {
    await service.close();
  });

  // The two groups below are about timers — recovery backoff, the silent
  // subscribe timeout, the Presence window — so they run on fake time (GH-40).
  // On real timers they failed on a busy machine. flutter_tester drains
  // microtasks only after every timer that is already overdue has fired, so
  // when a stall made both the service's timer and the test's own
  // Future.delayed overdue, the test woke up before the rebuild the service's
  // timer had started was finished ("keeps the socket": releasedSocket was
  // still empty). And the Presence window was measured on the wall clock, so
  // a slow loop let the window roll over and a fifth update through. On fake
  // time every timer fires at its due time with the microtasks of the ones
  // before it finished, and the service reads that same clock.
  group('a broken room channel', () {
    late List<_FakeRoomChannel> built;
    late List<RealtimeConnectionStatus> statuses;
    late RealtimeService realtime;

    void brokenChannelTest(String description, void Function(FakeAsync) body) {
      test(description, () {
        fakeAsync((async) {
          built = [];
          statuses = [];
          // Built inside the fake zone, so its timers and futures are fake.
          realtime = RealtimeService(
            channelFactory: (name, key) {
              final channel = _FakeRoomChannel(name, key);
              built.add(channel);
              return channel;
            },
            recoveryDelay: const Duration(milliseconds: 20),
            silentSubscribeTimeout: const Duration(milliseconds: 60),
            presenceCoalesceDelay: Duration.zero,
          );
          realtime.connectionStream.listen((e) => statuses.add(e.status));
          body(async);
          _settle(async, realtime.close());
        });
      });
    }

    void joinAndSubscribe(FakeAsync async) {
      _settle(
        async,
        realtime.joinRoom(
          roomCode: 'ABC234',
          userId: 'alice',
          nickname: 'Alice',
          avatarColorIndex: 1,
          hasBook: true,
          bookHash: 'book',
          isReading: true,
        ),
      );
      built.last.emitStatus(RealtimeSubscribeStatus.subscribed);
      async.elapse(Duration.zero);
      expect(realtime.isConnected, isTrue);
    }

    brokenChannelTest('is rebuilt on the room code topic', (async) {
      // GH-31: the server authorizes only `cotime_book:room:<code>`; a
      // rebuild on any other topic would be refused and leave the room
      // disconnected.
      joinAndSubscribe(async);
      built.first.emitStatus(RealtimeSubscribeStatus.closed);
      async.elapse(const Duration(milliseconds: 60));

      expect(built, hasLength(2));
      expect(
        built.map((channel) => channel.name),
        everyElement('cotime_book:room:ABC234'),
      );
    });

    brokenChannelTest('is rebuilt when the server or library closes it', (
      async,
    ) {
      // Regression: a closed channel is never rejoined by the library, so the
      // room stayed at "0 readers ready" until the app was restarted.
      joinAndSubscribe(async);
      built.first.emitStatus(RealtimeSubscribeStatus.closed);
      async.flushMicrotasks();
      expect(realtime.isConnected, isFalse);
      expect(statuses.last, RealtimeConnectionStatus.reconnecting);

      async.elapse(const Duration(milliseconds: 60));
      expect(built, hasLength(2));
      built.last.emitStatus(RealtimeSubscribeStatus.subscribed);
      async.elapse(Duration.zero);

      expect(realtime.isConnected, isTrue);
      // The new channel announces this reader again, page and all.
      expect(built.last.tracked.last['is_reading'], isTrue);
    });

    brokenChannelTest('keeps the socket when replacing a channel', (async) {
      // Regression: removing the last channel started an unawaited socket
      // disconnect that cancelled the reconnect the replacement needed, so
      // it reported "unable to subscribe" forever.
      joinAndSubscribe(async);
      built.first.emitStatus(RealtimeSubscribeStatus.channelError);
      async.elapse(const Duration(milliseconds: 60));

      expect(built.first.releasedSocket, [false]);
      _settle(async, realtime.leaveRoom());
      expect(built.last.releasedSocket, [true]);
    });

    brokenChannelTest('is left alone when the library recovers it in time', (
      async,
    ) {
      joinAndSubscribe(async);
      built.first.emitStatus(RealtimeSubscribeStatus.channelError);
      built.first.emitStatus(RealtimeSubscribeStatus.subscribed);
      async.elapse(const Duration(milliseconds: 60));

      expect(built, hasLength(1));
      expect(realtime.isConnected, isTrue);
    });

    brokenChannelTest('keeps retrying until a rebuild sticks', (async) {
      joinAndSubscribe(async);
      built.first.emitStatus(RealtimeSubscribeStatus.closed);
      async.elapse(const Duration(milliseconds: 40));
      expect(built, hasLength(2));
      built.last.emitStatus(RealtimeSubscribeStatus.timedOut);
      async.elapse(const Duration(milliseconds: 120));

      expect(built.length, greaterThanOrEqualTo(3));
      built.last.emitStatus(RealtimeSubscribeStatus.subscribed);
      async.elapse(Duration.zero);
      expect(realtime.isConnected, isTrue);
    });

    brokenChannelTest('a subscription that never answers is rebuilt', (async) {
      _settle(
        async,
        realtime.joinRoom(
          roomCode: 'ABC234',
          userId: 'alice',
          nickname: 'Alice',
          avatarColorIndex: 1,
          hasBook: false,
        ),
      );
      async.elapse(const Duration(milliseconds: 59));
      expect(built, hasLength(1));
      async.elapse(const Duration(milliseconds: 1));
      expect(built, hasLength(2));
    });

    brokenChannelTest('is not rebuilt after the room is left', (async) {
      joinAndSubscribe(async);
      built.first.emitStatus(RealtimeSubscribeStatus.closed);
      _settle(async, realtime.leaveRoom());
      async.elapse(const Duration(milliseconds: 80));
      expect(built, hasLength(1));
    });

    group('refused by the server (GH-36)', () {
      late List<RealtimeAccessDenied> refusals;

      void listenForRefusals() {
        refusals = [];
        realtime.accessDeniedStream.listen(refusals.add);
      }

      brokenChannelTest('is not rebuilt, and is reported once', (async) {
        // Regression: the watchdog rebuilt a channel the server had refused
        // because the user was no longer a member, logging "Unauthorized"
        // every few seconds for as long as the app stayed open.
        listenForRefusals();
        joinAndSubscribe(async);
        built.first.emitStatus(
          RealtimeSubscribeStatus.channelError,
          _unauthorized,
        );
        // Longer than both the recovery delay and the silent timeout.
        async.elapse(const Duration(milliseconds: 150));

        expect(built, hasLength(1));
        expect(refusals, hasLength(1));
        expect(refusals.single.roomCode, 'ABC234');
        expect(realtime.isConnected, isFalse);
        expect(statuses.last, RealtimeConnectionStatus.error);
        // Dropped, so the library does not rejoin it on a socket reconnect;
        // the socket stays for whatever comes next.
        expect(built.first.releasedSocket, [false]);
      });

      brokenChannelTest('an app resume does not knock again', (async) {
        listenForRefusals();
        joinAndSubscribe(async);
        built.first.emitStatus(
          RealtimeSubscribeStatus.channelError,
          _unauthorized,
        );
        realtime.checkConnection(delay: Duration.zero);
        async.elapse(const Duration(milliseconds: 50));
        expect(built, hasLength(1));
      });

      brokenChannelTest(
        'is tried again when the room says this is still a member',
        (async) {
          listenForRefusals();
          joinAndSubscribe(async);
          built.first.emitStatus(
            RealtimeSubscribeStatus.channelError,
            _unauthorized,
          );
          async.flushMicrotasks();
          expect(refusals, hasLength(1));

          realtime.retryAfterAccessDenied(refusals.single.generation);
          // Past the recovery delay, short of the new channel's silent
          // timeout.
          async.elapse(const Duration(milliseconds: 30));
          expect(built, hasLength(2));
          built.last.emitStatus(RealtimeSubscribeStatus.subscribed);
          async.elapse(Duration.zero);
          expect(realtime.isConnected, isTrue);
          // The new channel announces this reader again.
          expect(built.last.tracked.last['is_reading'], isTrue);
        },
      );

      brokenChannelTest('a retry for a room already left does nothing', (
        async,
      ) {
        listenForRefusals();
        joinAndSubscribe(async);
        built.first.emitStatus(
          RealtimeSubscribeStatus.channelError,
          _unauthorized,
        );
        async.flushMicrotasks();
        expect(refusals, hasLength(1));
        _settle(async, realtime.leaveRoom());

        realtime.retryAfterAccessDenied(refusals.single.generation);
        async.elapse(const Duration(milliseconds: 100));
        expect(built, hasLength(1));
        expect(realtime.roomCode, isNull);
      });

      brokenChannelTest('a dropped connection is still rebuilt', (async) {
        listenForRefusals();
        joinAndSubscribe(async);
        built.first.emitStatus(
          RealtimeSubscribeStatus.channelError,
          Exception('socket closed'),
        );
        async.elapse(const Duration(milliseconds: 60));
        expect(built, hasLength(2));
        expect(refusals, isEmpty);
      });
    });

    brokenChannelTest('is not rebuilt once leaving has started', (async) {
      // Regression (GH-36): between the leave RPC and dropping the channel,
      // a rebuilt channel was refused because the membership was gone.
      joinAndSubscribe(async);
      final refusals = <RealtimeAccessDenied>[];
      realtime.accessDeniedStream.listen(refusals.add);

      realtime.suspendRecovery();
      built.first.emitStatus(RealtimeSubscribeStatus.closed);
      async.elapse(const Duration(milliseconds: 150));
      expect(built, hasLength(1));

      // Nothing to tell anyone: this device is the one leaving.
      built.first.emitStatus(
        RealtimeSubscribeStatus.channelError,
        _unauthorized,
      );
      async.flushMicrotasks();
      expect(refusals, isEmpty);

      _settle(async, realtime.leaveRoom());
      // The next room is watched again.
      joinAndSubscribe(async);
      built.last.emitStatus(RealtimeSubscribeStatus.closed);
      async.elapse(const Duration(milliseconds: 60));
      expect(built, hasLength(3));
    });

    brokenChannelTest('an app resume checks a channel that is down', (async) {
      joinAndSubscribe(async);
      built.first.emitStatus(RealtimeSubscribeStatus.timedOut);
      realtime.checkConnection(delay: Duration.zero);
      // Sooner than the 20ms backoff the timeout itself scheduled.
      async.elapse(const Duration(milliseconds: 10));
      expect(built, hasLength(2));
    });
  });

  group('Presence updates', () {
    // Supabase closes the channel of a client that sends more than five
    // Presence updates in 30 seconds (ClientPresenceRateLimitReached).
    late _FakeRoomChannel channel;
    late RealtimeService realtime;

    void presenceTest(String description, void Function(FakeAsync) body) {
      test(description, () {
        fakeAsync((async) {
          // The window is measured on the same fake clock the timers run on.
          final clock = async.getClock(DateTime.utc(2026, 10, 22));
          realtime = RealtimeService(
            channelFactory: (name, key) =>
                channel = _FakeRoomChannel(name, key),
            presenceCoalesceDelay: const Duration(milliseconds: 10),
            presenceWindow: const Duration(milliseconds: 200),
            clock: clock.now,
          );
          _settle(
            async,
            realtime.joinRoom(
              roomCode: 'ABC234',
              userId: 'alice',
              nickname: 'Alice',
              avatarColorIndex: 1,
              hasBook: false,
            ),
          );
          channel.emitStatus(RealtimeSubscribeStatus.subscribed);
          async.elapse(const Duration(milliseconds: 30));
          expect(channel.tracked, hasLength(1));

          body(async);
          _settle(async, realtime.close());
        });
      });
    }

    void update(FakeAsync async, {bool reading = true, bool ready = true}) {
      _settle(
        async,
        realtime.updatePresence(
          userId: 'alice',
          nickname: 'Alice',
          avatarColorIndex: 1,
          hasBook: true,
          isReading: reading,
          readerReady: ready,
        ),
      );
    }

    presenceTest(
      'a burst of changes goes out as one update with the last value',
      (async) {
        update(async, ready: false);
        update(async, reading: true, ready: false);
        update(async, reading: true, ready: true);
        async.elapse(const Duration(milliseconds: 40));

        expect(channel.tracked, hasLength(2));
        expect(channel.tracked.last['reader_ready'], isTrue);
      },
    );

    presenceTest('never more than four updates per window', (async) {
      // Regression: a Presence update per page turn hit Supabase's limit
      // within a few pages, and the server closed the room channel.
      for (var i = 0; i < 8; i++) {
        update(async, ready: i.isEven);
        async.elapse(const Duration(milliseconds: 20));
      }
      expect(channel.tracked, hasLength(4));

      // The latest state still arrives once the window allows it.
      async.elapse(const Duration(milliseconds: 250));
      expect(channel.tracked, hasLength(5));
      expect(channel.tracked.last['reader_ready'], isFalse);
    });
  });

  test('room event registry includes lifecycle and commit events', () {
    // Every event the page sync protocol listens to. Regression: the ad
    // break announcement was not registered, so no reader ever heard another
    // one's ad start (GH-63).
    expect(
      RealtimeService.roomEvents,
      containsAll([
        PageSyncService.requestEvent,
        PageSyncService.voteEvent,
        PageSyncService.commitEvent,
        PageSyncService.cancelEvent,
        PageSyncService.positionQueryEvent,
        PageSyncService.positionEvent,
        PageSyncService.readerLeftEvent,
        PageSyncService.membershipEvent,
        PageSyncService.adBreakEvent,
      ]),
    );
    expect(
      RealtimeService.roomEvents,
      containsAll([
        'book_chunk',
        'transfer_request',
        'membership_changed',
        'room_closed',
      ]),
    );
  });

  test('Presence says this app sends books directly (GH-60)', () async {
    await service.joinRoom(
      roomCode: 'abc234',
      userId: 'alice',
      nickname: 'Alice',
      avatarColorIndex: 2,
      hasBook: false,
    );
    channels.single.emitStatus(RealtimeSubscribeStatus.subscribed);
    await Future<void>.delayed(Duration.zero);

    expect(
      channels.single.tracked.single['direct_transfer'],
      AppConstants.directBookTransfer,
    );
  });

  test('direct transfer signals reach the book link (GH-60)', () async {
    // Regression: the signal event was not registered on the channel, so no
    // offer or answer ever arrived and every direct fetch timed out.
    await service.joinRoom(
      roomCode: 'abc234',
      userId: 'alice',
      nickname: 'Alice',
      avatarColorIndex: 2,
      hasBook: false,
    );
    channels.single.emitStatus(RealtimeSubscribeStatus.subscribed);
    await Future<void>.delayed(Duration.zero);

    final transport = RealtimeBookTransferTransport(service);
    final received = transport
        .broadcastStream(SignalingBookPeerLink.signalEvent)
        .first;
    channels.single.emitBroadcast(SignalingBookPeerLink.signalEvent, {
      'kind': 'offer',
      'to_user': 'alice',
    });

    expect((await received)['kind'], 'offer');
  });

  test('same-room join is idempotent and updates presence', () async {
    await service.joinRoom(
      roomCode: 'abc234',
      userId: 'alice',
      nickname: 'Alice',
      avatarColorIndex: 2,
      hasBook: false,
    );
    expect(channels, hasLength(1));
    expect(service.isConnected, isFalse);

    channels.single.emitStatus(RealtimeSubscribeStatus.subscribed);
    await Future<void>.delayed(Duration.zero);
    expect(service.isConnected, isTrue);
    expect(channels.single.tracked.single['has_book'], isFalse);

    await service.joinRoom(
      roomCode: 'ABC234',
      userId: 'alice',
      nickname: 'Alice',
      avatarColorIndex: 2,
      hasBook: true,
      readerReady: true,
    );
    // Presence updates are coalesced, so they go out on the next tick.
    await Future<void>.delayed(const Duration(milliseconds: 5));

    expect(channels, hasLength(1));
    expect(channels.single.tracked.last['has_book'], isTrue);
    expect(channels.single.tracked.last['reader_ready'], isTrue);
  });

  test('Presence carries the protocol version in its first update', () async {
    // GH-33: a member on another protocol must be recognisable. Static, so it
    // goes out with the join's track and costs no update of its own.
    await _join(service, 'ABC234');
    channels.single.emitStatus(RealtimeSubscribeStatus.subscribed);
    await Future<void>.delayed(const Duration(milliseconds: 5));

    expect(channels.single.tracked, hasLength(1));
    expect(
      channels.single.tracked.single['protocol'],
      AppConstants.roomProtocolVersion,
    );
  });

  test('only a refused topic counts as access denied', () {
    // The shape realtime_client 2.10.0 reports a refused join in.
    expect(isRealtimeAccessDenied(_unauthorized), isTrue);
    expect(isRealtimeAccessDenied(Exception('"timeout"')), isFalse);
    expect(isRealtimeAccessDenied(null), isFalse);
  });

  test('online users collapse a user with several connections', () async {
    await _join(service, 'ABC234');
    channels.single
      ..emitStatus(RealtimeSubscribeStatus.subscribed)
      ..presences = [
        {
          'user_id': 'alice',
          'nickname': 'Alice phone',
          'is_reading': true,
          'reader_ready': true,
          'online_at': '2026-08-12T01:00:00Z',
        },
        {
          'user_id': 'alice',
          'nickname': 'Alice tablet',
          'is_reading': false,
          'reader_ready': false,
          'online_at': '2026-08-12T02:00:00Z',
        },
      ];
    await Future<void>.delayed(Duration.zero);

    final users = service.getOnlineUsers();
    expect(users, hasLength(1));
    // A second, idle connection must not make the reader look unready: that
    // silently removed the user from every other client's page-turn quorum.
    expect(users.single['is_reading'], isTrue);
    expect(users.single['reader_ready'], isTrue);
    expect(users.single['nickname'], 'Alice tablet');
  });

  test('concurrent same-room joins share one channel', () async {
    await Future.wait([
      _join(service, 'AAA234'),
      _join(service, 'AAA234'),
      _join(service, 'aaa234'),
    ]);

    expect(channels, hasLength(1));
  });

  test(
    'same room with a different authenticated user replaces channel',
    () async {
      await _join(service, 'AAA234');
      channels.single.emitStatus(RealtimeSubscribeStatus.subscribed);
      await Future<void>.delayed(Duration.zero);

      await service.joinRoom(
        roomCode: 'AAA234',
        userId: 'bob',
        nickname: 'Bob',
        avatarColorIndex: 1,
        hasBook: false,
      );

      expect(channels, hasLength(2));
      expect(channels.first.untrackCount, 1);
      expect(channels.first.removeCount, 1);
      expect(channels.last.presenceKey, 'bob');
    },
  );

  test('cross-room join completely removes old channel', () async {
    await _join(service, 'AAA234');
    channels.single.emitStatus(RealtimeSubscribeStatus.subscribed);
    await Future<void>.delayed(Duration.zero);

    await _join(service, 'BBB234');

    expect(channels, hasLength(2));
    expect(channels.first.untrackCount, 1);
    expect(channels.first.removeCount, 1);
    expect(service.roomCode, 'BBB234');
  });

  test('channel removal still runs when presence untrack fails', () async {
    await _join(service, 'AAA234');
    channels.single.emitStatus(RealtimeSubscribeStatus.subscribed);
    await Future<void>.delayed(Duration.zero);
    channels.single.untrackError = StateError('socket closed');

    await expectLater(service.leaveRoom(), throwsStateError);

    expect(channels.single.untrackCount, 1);
    expect(channels.single.removeCount, 1);
    expect(service.roomCode, isNull);
  });

  test('callbacks from an obsolete generation are ignored', () async {
    final received = <Map<String, dynamic>>[];
    final subscription = service
        .broadcastStream('book_shared')
        .listen(received.add);

    await _join(service, 'AAA234');
    final oldChannel = channels.single;
    await _join(service, 'BBB234');
    final currentChannel = channels.last;

    oldChannel.emitBroadcast('book_shared', {'room': 'old'});
    currentChannel.emitBroadcast('book_shared', {'room': 'new'});
    await Future<void>.delayed(Duration.zero);

    expect(received, [
      {'room': 'new'},
    ]);
    await subscription.cancel();
  });

  test('presence sync exposes current generation payloads', () async {
    final events = <Map<String, dynamic>>[];
    final subscription = service.presenceStream.listen(events.add);
    await _join(service, 'AAA234');
    channels.single.presences = [
      {'user_id': 'alice'},
      {'user_id': 'bob'},
    ];

    channels.single.emitPresenceSync();
    await Future<void>.delayed(Duration.zero);

    expect(events.single['event'], 'sync');
    expect(events.single['state'], hasLength(2));
    await subscription.cancel();
  });
}

/// Runs [future] to completion on fake time: its microtasks, not its timers.
/// Throws what it throws, and fails if it is still waiting on a timer.
T _settle<T>(FakeAsync async, Future<T> future) {
  late T value;
  Object? error;
  StackTrace? stackTrace;
  var done = false;
  future.then(
    (v) {
      value = v;
      done = true;
    },
    onError: (Object e, StackTrace s) {
      error = e;
      stackTrace = s;
      done = true;
    },
  );
  async.flushMicrotasks();
  if (!done) fail('the future is waiting on a timer');
  if (error != null) Error.throwWithStackTrace(error!, stackTrace!);
  return value;
}

/// A join refused because the user may not read the room's topic.
final _unauthorized = Exception(
  '"Unauthorized: You do not have permissions to read from this Channel '
  'topic: cotime_book:room:ABC234"',
);

Future<void> _join(RealtimeService service, String code) {
  return service.joinRoom(
    roomCode: code,
    userId: 'alice',
    nickname: 'Alice',
    avatarColorIndex: 0,
    hasBook: false,
  );
}

class _FakeRoomChannel implements RoomRealtimeChannel {
  final String name;
  final String presenceKey;
  VoidCallback? _sync;
  ValueChanged<dynamic>? _join;
  ValueChanged<dynamic>? _leave;
  void Function(RealtimeSubscribeStatus, Object?)? _status;
  final callbacks = <String, ValueChanged<Map<String, dynamic>>>{};
  final tracked = <Map<String, dynamic>>[];
  List<Map<String, dynamic>> presences = [];
  int untrackCount = 0;
  int removeCount = 0;
  Object? untrackError;

  _FakeRoomChannel(this.name, this.presenceKey);

  @override
  void onPresenceSync(VoidCallback callback) => _sync = callback;

  @override
  void onPresenceJoin(ValueChanged<dynamic> callback) => _join = callback;

  @override
  void onPresenceLeave(ValueChanged<dynamic> callback) => _leave = callback;

  @override
  void onBroadcast(String event, ValueChanged<Map<String, dynamic>> callback) {
    callbacks[event] = callback;
  }

  @override
  void subscribe(
    void Function(RealtimeSubscribeStatus status, Object? error) callback,
  ) {
    _status = callback;
  }

  @override
  Future<void> track(Map<String, dynamic> payload) async {
    tracked.add(Map<String, dynamic>.from(payload));
  }

  @override
  Future<void> untrack() async {
    untrackCount++;
    final error = untrackError;
    if (error != null) throw error;
  }

  @override
  Future<void> sendBroadcast(String event, Map<String, dynamic> payload) async {
    emitBroadcast(event, payload);
  }

  @override
  List<Map<String, dynamic>> presencePayloads() => presences;

  @override
  Future<void> remove({bool releaseSocket = true}) async {
    removeCount++;
    releasedSocket.add(releaseSocket);
  }

  final releasedSocket = <bool>[];

  void emitStatus(RealtimeSubscribeStatus status, [Object? error]) {
    _status?.call(status, error);
  }

  void emitPresenceJoin(dynamic payload) => _join?.call(payload);

  void emitPresenceLeave(dynamic payload) => _leave?.call(payload);

  void emitPresenceSync() => _sync?.call();

  void emitBroadcast(String event, Map<String, dynamic> payload) {
    callbacks[event]?.call(payload);
  }
}
