import 'dart:async';

import 'package:cotime_book/models/room.dart';
import 'package:cotime_book/providers/presence_provider.dart';
import 'package:cotime_book/providers/room_provider.dart';
import 'package:cotime_book/services/realtime_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart'
    show RealtimeSubscribeStatus;

import 'room_provider_test.dart' show FakeRoomService, testRoom;

/// GH-36: Realtime refusing the room channel, end to end through the room
/// session.
void main() {
  late FakeRoomService rooms;
  late List<_ChannelStub> channels;
  late RealtimeService realtime;
  late ProviderContainer container;

  setUp(() async {
    rooms = FakeRoomService();
    channels = [];
    realtime = RealtimeService(
      channelFactory: (name, key) {
        final channel = _ChannelStub();
        channels.add(channel);
        return channel;
      },
      recoveryDelay: const Duration(milliseconds: 10),
      presenceCoalesceDelay: Duration.zero,
    );
    container = ProviderContainer(
      overrides: [
        roomServiceProvider.overrideWithValue(rooms),
        realtimeServiceProvider.overrideWithValue(realtime),
      ],
    );
    await container.read(roomProvider.notifier).joinRoom('AAAAAA', 'Alice');
    await container
        .read(presenceProvider.notifier)
        .joinRoom(
          roomCode: 'AAAAAA',
          userId: 'alice',
          nickname: 'Alice',
          avatarColorIndex: 0,
        );
    channels.single.emit(RealtimeSubscribeStatus.subscribed);
    await _eventually(() => realtime.isConnected);
  });

  tearDown(() async {
    await realtime.close();
    container.dispose();
  });

  test('a member removed from the room is taken out of it, in words', () async {
    // Regression: after the membership was gone, the watchdog kept asking
    // for the channel every few seconds and the app sat in a dead room.
    rooms.roomRead = Completer<Room?>()..complete(null);
    channels.single.emit(RealtimeSubscribeStatus.channelError, _unauthorized);

    await _eventually(() => container.read(roomProvider).currentRoom == null);
    expect(
      container.read(roomProvider).error,
      RoomNotifier.removedFromRoomMessage,
    );
    await _eventually(() => realtime.roomCode == null);
    expect(channels, hasLength(1));
  });

  test('a refusal the database does not back up is tried again', () async {
    // Still a member as far as the database knows: a stale token, say.
    channels.single.emit(RealtimeSubscribeStatus.channelError, _unauthorized);

    await _eventually(() => channels.length == 2);
    expect(container.read(roomProvider).currentRoom?.id, testRoom().id);
    expect(container.read(roomProvider).error, isNull);
  });

  test('a refusal answered after leaving began changes nothing', () async {
    // The check races the leave: its answer must not turn a deliberate leave
    // into "you are no longer in this room".
    final read = Completer<Room?>();
    rooms.roomRead = read;
    channels.single.emit(RealtimeSubscribeStatus.channelError, _unauthorized);
    await Future<void>.delayed(Duration.zero);

    await container.read(roomProvider.notifier).leaveRoom();
    read.complete(null);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(container.read(roomProvider).currentRoom, isNull);
    expect(container.read(roomProvider).error, isNull);
    expect(channels, hasLength(1));
  });
}

final _unauthorized = Exception(
  '"Unauthorized: You do not have permissions to read from this Channel '
  'topic: cotime_book:room:AAAAAA"',
);

/// Waits for [condition] without depending on timer or microtask order.
Future<void> _eventually(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('condition never became true');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

class _ChannelStub implements RoomRealtimeChannel {
  void Function(RealtimeSubscribeStatus, Object?)? _status;

  void emit(RealtimeSubscribeStatus status, [Object? error]) =>
      _status?.call(status, error);

  @override
  void onPresenceSync(VoidCallback callback) {}

  @override
  void onPresenceJoin(ValueChanged<dynamic> callback) {}

  @override
  void onPresenceLeave(ValueChanged<dynamic> callback) {}

  @override
  void onBroadcast(String event, ValueChanged<Map<String, dynamic>> callback) {}

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
  List<Map<String, dynamic>> presencePayloads() => const [];

  @override
  Future<void> remove({bool releaseSocket = true}) async {}
}
