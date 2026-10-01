import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/recent_room.dart';

/// What this device remembers between launches.
///
/// Backed by [SharedPreferences] when one is available. Without it (tests, or
/// a platform where the plugin failed to load) everything is kept in memory
/// for the session: forgetting a nickname is an inconvenience, refusing to
/// start the app over it would not be.
class LocalStore {
  static const _nicknameKey = 'nickname';
  static const _recentRoomsKey = 'recent_rooms';

  final SharedPreferences? _prefs;
  String? _nickname;
  List<RecentRoom>? _recentRooms;

  LocalStore([this._prefs]);

  String get nickname => _nickname ??= _prefs?.getString(_nicknameKey) ?? '';

  Future<void> saveNickname(String nickname) async {
    _nickname = nickname;
    await _write(() => _prefs?.setString(_nicknameKey, nickname));
  }

  List<RecentRoom> get recentRooms => _recentRooms ??= _readRecentRooms();

  Future<void> saveRecentRooms(List<RecentRoom> rooms) async {
    _recentRooms = List.unmodifiable(rooms);
    await _write(
      () => _prefs?.setString(
        _recentRoomsKey,
        jsonEncode([for (final room in rooms) room.toJson()]),
      ),
    );
  }

  List<RecentRoom> _readRecentRooms() {
    final raw = _prefs?.getString(_recentRoomsKey);
    if (raw == null) return const [];
    // One malformed entry (an older format, a partial write) must not take
    // the rest of the list, or the home screen, down with it.
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return List.unmodifiable([
        for (final entry in decoded)
          if (entry is Map<String, dynamic>)
            if (_tryParse(entry) case final room?) room,
      ]);
    } on FormatException {
      return const [];
    }
  }

  RecentRoom? _tryParse(Map<String, dynamic> json) {
    try {
      return RecentRoom.fromJson(json);
    } catch (_) {
      return null;
    }
  }

  Future<void> _write(Future<bool>? Function() write) async {
    try {
      await write();
    } catch (error) {
      debugPrint('Unable to save local preferences: $error');
    }
  }
}
