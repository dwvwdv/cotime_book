import 'package:cotime_book/models/room.dart';
import 'package:cotime_book/models/room_text_size.dart';
import 'package:cotime_book/models/shared_page.dart';
import 'package:cotime_book/providers/reading_preferences_provider.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

Room _room({bool? locked, int? textSize}) {
  final json = <String, dynamic>{
    'id': 'room-a',
    'code': 'AAAAAA',
    'host_user_id': 'host',
    'created_at': '2026-10-23T00:00:00Z',
    'updated_at': '2026-10-23T00:00:00Z',
    'text_size': textSize,
  };
  if (locked != null) json['text_size_locked'] = locked;
  return Room.fromJson(json);
}

void main() {
  test('a room is host-sized unless it says otherwise', () {
    // A database from before the column sends nothing: the default applies.
    expect(_room().textSizeLocked, isTrue);
    expect(_room(locked: false).textSizeLocked, isFalse);
    expect(_room(textSize: 24).textSize, 24);
    expect(Room.fromJson(_room(textSize: 24).toJson()).textSize, 24);
    expect(_room(textSize: 24).copyWith(textSize: null).textSize, isNull);
  });

  test('while the host sets it, a reader\'s own size does not count', () {
    final reader = RoomTextSize.of(
      _room(locked: true, textSize: 20),
      isHost: false,
    );

    expect(reader.canChange, isFalse);
    expect(reader.requested(28), 20);
  });

  test('the host asks for the room\'s size and can change it', () {
    final host = RoomTextSize.of(_room(textSize: 20), isHost: true);

    expect(host.canChange, isTrue);
    expect(host.needsRoomSize, isFalse);
    expect(host.requested(28), 20);
  });

  test('a locked room without a size takes the host\'s', () {
    final host = RoomTextSize.of(_room(), isHost: true);
    final reader = RoomTextSize.of(_room(), isHost: false);

    expect(host.needsRoomSize, isTrue);
    expect(host.requested(24), 24);
    // Not their own 28, which would set the type for the whole room.
    expect(reader.requested(28), ReadingPreferences.defaultFontSize);
  });

  test('unlocked, everyone asks for their own size again', () {
    final reader = RoomTextSize.of(
      _room(locked: false, textSize: 20),
      isHost: false,
    );

    expect(reader.canChange, isTrue);
    expect(reader.requested(28), 28);
  });

  test('a stored size outside what the app offers is clamped', () {
    expect(
      RoomTextSize.of(_room(textSize: 99), isHost: false).requested(18),
      ReadingPreferences.maxFontSize,
    );
  });

  test('with the lock on, a reader turning up the type moves nobody', () {
    // The room reads at the largest size anyone asks for (issue #20); while
    // the host sets the size, a reader's own size is never what they ask for.
    const viewer = Size(400, 700);
    final room = _room(textSize: 18);
    final hostFit = PageFit.of(
      viewer,
      fontSize: RoomTextSize.of(room, isHost: true).requested(18),
    );
    final readerFit = PageFit.of(
      viewer,
      fontSize: RoomTextSize.of(room, isHost: false).requested(32),
    );

    final page = SharedPage.forRoom(
      own: hostFit,
      onlineUsers: [
        {'is_reading': true, 'page_fit': readerFit.toWire()},
      ],
    );

    expect(page.fontSize, 18);
  });
}
