import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/recent_room.dart';
import '../models/room.dart';
import '../services/local_store.dart';
import 'auth_provider.dart';
import 'local_store_provider.dart';
import 'room_provider.dart';

final recentRoomsProvider =
    StateNotifierProvider<RecentRoomsNotifier, List<RecentRoom>>((ref) {
      final notifier = RecentRoomsNotifier(
        ref.read(localStoreProvider),
        availableCodes: ref.read(roomServiceProvider).availableRoomCodes,
      );
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
      // The availability check needs a session, and the app signs in after
      // the home screen is already up.
      ref.listen<AuthState>(authProvider, (previous, next) {
        if (next.isAuthenticated && previous?.userId != next.userId) {
          notifier.pruneUnavailable();
        }
      }, fireImmediately: true);
      return notifier;
    });

class RecentRoomsNotifier extends StateNotifier<List<RecentRoom>> {
  static const maxEntries = 8;

  final LocalStore _store;
  final DateTime Function() _now;
  final Future<Set<String>> Function(List<String> codes)? _availableCodes;
  int _pruneGeneration = 0;

  RecentRoomsNotifier(
    this._store, {
    DateTime Function()? now,
    Future<Set<String>> Function(List<String> codes)? availableCodes,
  }) : _now = now ?? DateTime.now,
       _availableCodes = availableCodes,
       super(_store.recentRooms);

  /// Drops rooms that no longer exist. A closed room stays on the list — any
  /// former member can reopen it — until cleanup deletes it 30 days later.
  Future<void> pruneUnavailable() async {
    final check = _availableCodes;
    if (check == null || state.isEmpty) return;
    final generation = ++_pruneGeneration;
    final checked = {for (final room in state) room.code};
    final Set<String> available;
    try {
      available = await check(checked.toList(growable: false));
    } catch (error) {
      // Offline is not "gone". Keep the list and try again next launch.
      debugPrint('Unable to check recent rooms: $error');
      return;
    }
    // A room entered while the check was in flight is available by
    // definition, and its answer may predate the visit.
    if (!mounted || generation != _pruneGeneration) return;
    final gone = checked.difference(available);
    if (gone.isEmpty) return;
    _save(
      state.where((r) => !gone.contains(r.code)).toList(growable: false),
    );
  }

  void record(Room room) {
    _pruneGeneration++;
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
