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
