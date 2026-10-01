import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/recent_room.dart';
import '../models/room.dart';
import '../services/local_store.dart';
import 'local_store_provider.dart';
import 'room_provider.dart';

final recentRoomsProvider =
    StateNotifierProvider<RecentRoomsNotifier, List<RecentRoom>>((ref) {
      final notifier = RecentRoomsNotifier(ref.read(localStoreProvider));
      // Recorded from the room state rather than from the buttons that enter
      // a room, so every way in (create, join, a recent entry) is covered, and
      // the book title follows when it is chosen in the lobby.
      ref.listen<RoomState>(roomProvider, (previous, next) {
        final room = next.currentRoom;
        if (room == null) return;
        final before = previous?.currentRoom;
        if (before?.code == room.code &&
            before?.currentBookTitle == room.currentBookTitle) {
          return;
        }
        notifier.record(room);
      });
      return notifier;
    });

class RecentRoomsNotifier extends StateNotifier<List<RecentRoom>> {
  static const maxEntries = 8;

  final LocalStore _store;
  final DateTime Function() _now;

  RecentRoomsNotifier(this._store, {DateTime Function()? now})
    : _now = now ?? DateTime.now,
      super(_store.recentRooms);

  void record(Room room) {
    final existing = state.where((r) => r.code == room.code).firstOrNull;
    final entry = RecentRoom(
      code: room.code,
      // A room is created before its book is chosen; don't let that moment
      // erase the title remembered from the last visit.
      bookTitle: room.currentBookTitle ?? existing?.bookTitle,
      lastVisitedAt: _now(),
    );
    _save([
      entry,
      ...state.where((r) => r.code != room.code),
    ].take(maxEntries).toList(growable: false));
  }

  void remove(String code) {
    if (!state.any((r) => r.code == code)) return;
    _save(state.where((r) => r.code != code).toList(growable: false));
  }

  void _save(List<RecentRoom> rooms) {
    state = rooms;
    _store.saveRecentRooms(rooms);
  }
}
