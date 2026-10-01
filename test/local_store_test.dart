import 'dart:async';

import 'package:cotime_book/models/recent_room.dart';
import 'package:cotime_book/providers/auth_provider.dart';
import 'package:cotime_book/providers/recent_rooms_provider.dart';
import 'package:cotime_book/services/local_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'room_provider_test.dart' show testRoom;

/// A store as the next launch of the app would see it: same preferences on
/// disk, nothing carried over in memory.
Future<LocalStore> relaunch() async =>
    LocalStore(await SharedPreferences.getInstance());

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('nickname', () {
    test('is remembered across launches', () async {
      AuthNotifier(await relaunch()).setNickname('Alice');
      await pumpEventQueue();

      expect(AuthNotifier(await relaunch()).state.nickname, 'Alice');
    });

    test('starts empty on a first launch', () async {
      expect(AuthNotifier(await relaunch()).state.nickname, '');
    });
  });

  group('recent rooms', () {
    var clock = DateTime.utc(2026, 10, 1, 9);
    RecentRoomsNotifier notifierFor(LocalStore store) =>
        RecentRoomsNotifier(store, now: () => clock);

    test('are remembered across launches, newest first', () async {
      final rooms = notifierFor(await relaunch());
      rooms.record(testRoom(code: 'AAAAAA'));
      clock = clock.add(const Duration(hours: 1));
      rooms.record(testRoom(code: 'BBBBBB'));
      await pumpEventQueue();

      final codes = notifierFor(await relaunch()).state.map((r) => r.code);
      expect(codes, ['BBBBBB', 'AAAAAA']);
    });

    test('going back to a room moves it to the top without a duplicate', () async {
      final rooms = notifierFor(await relaunch());
      rooms.record(testRoom(code: 'AAAAAA'));
      rooms.record(testRoom(code: 'BBBBBB'));
      rooms.record(testRoom(code: 'AAAAAA'));

      expect(rooms.state.map((r) => r.code), ['AAAAAA', 'BBBBBB']);
    });

    test('keep the book title when a visit starts before the book is set', () async {
      final rooms = notifierFor(await relaunch());
      rooms.record(
        testRoom(code: 'AAAAAA').copyWith(currentBookTitle: 'Moby-Dick'),
      );
      rooms.record(testRoom(code: 'AAAAAA'));

      expect(rooms.state.single.bookTitle, 'Moby-Dick');
    });

    test('only the most recent few are kept', () async {
      final rooms = notifierFor(await relaunch());
      for (var i = 0; i < RecentRoomsNotifier.maxEntries + 3; i++) {
        rooms.record(testRoom(code: 'ROOM${i.toString().padLeft(2, '0')}'));
      }

      expect(rooms.state, hasLength(RecentRoomsNotifier.maxEntries));
      expect(rooms.state.first.code, 'ROOM10');
    });

    test('a removed room stays removed after a relaunch', () async {
      final rooms = notifierFor(await relaunch());
      rooms.record(testRoom(code: 'AAAAAA'));
      rooms.record(testRoom(code: 'BBBBBB'));
      rooms.remove('AAAAAA');
      await pumpEventQueue();

      final codes = notifierFor(await relaunch()).state.map((r) => r.code);
      expect(codes, ['BBBBBB']);
    });

    test('an unreadable saved list does not break the home screen', () async {
      SharedPreferences.setMockInitialValues({
        'recent_rooms':
            '[{"code":"AAAAAA","last_visited_at":"2026-10-01T09:00:00Z"},'
            '{"code":42},"junk"]',
      });
      expect(
        (await relaunch()).recentRooms.map((r) => r.code),
        ['AAAAAA'],
      );

      SharedPreferences.setMockInitialValues({'recent_rooms': 'not json'});
      expect((await relaunch()).recentRooms, isEmpty);
    });

    test('a room entered while the check is in flight is not pruned', () async {
      final answer = Completer<Set<String>>();
      final rooms = RecentRoomsNotifier(
        await relaunch(),
        now: () => clock,
        availableCodes: (_) => answer.future,
      );
      rooms.record(testRoom(code: 'AAAAAA'));
      final pruning = rooms.pruneUnavailable();
      // Re-entered after the server was asked, so the stale "gone" must lose.
      rooms.record(testRoom(code: 'AAAAAA'));
      answer.complete(<String>{});
      await pruning;

      expect(rooms.state.map((r) => r.code), ['AAAAAA']);
    });

    test('a store without preferences still works for the session', () {
      final store = LocalStore();
      store.saveRecentRooms([
        RecentRoom(code: 'AAAAAA', lastVisitedAt: DateTime.utc(2026, 10, 1)),
      ]);
      expect(store.recentRooms.single.code, 'AAAAAA');
    });
  });
}
