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
  static const _readingThemeKey = 'reading_theme';
  static const _readingFontSizeKey = 'reading_font_size';
  static const _volumeKeysTurnPagesKey = 'volume_keys_turn_pages';

  final SharedPreferences? _prefs;
  String? _nickname;
  List<RecentRoom>? _recentRooms;

  /// What was saved this session, so a store without preferences still
  /// remembers it until the app closes.
  final Map<String, Object> _saved = {};

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

  // Reading preferences come back as whatever was on disk: null when missing
  // or of the wrong type. Whether a value is usable (a theme that still
  // exists, a size in range) is the reader's call, not the store's.

  String? get readingTheme => _read<String>(_readingThemeKey);

  Future<void> saveReadingTheme(String theme) => _save(
    _readingThemeKey,
    theme,
    () => _prefs?.setString(_readingThemeKey, theme),
  );

  double? get readingFontSize => _read<num>(_readingFontSizeKey)?.toDouble();

  Future<void> saveReadingFontSize(double size) => _save(
    _readingFontSizeKey,
    size,
    () => _prefs?.setDouble(_readingFontSizeKey, size),
  );

  bool? get volumeKeysTurnPages => _read<bool>(_volumeKeysTurnPagesKey);

  Future<void> saveVolumeKeysTurnPages(bool enabled) => _save(
    _volumeKeysTurnPagesKey,
    enabled,
    () => _prefs?.setBool(_volumeKeysTurnPagesKey, enabled),
  );

  /// The typed getters of [SharedPreferences] throw on a value of another
  /// type (an older format, a hand-edited file); this reads it as missing.
  T? _read<T>(String key) {
    final value = _saved.containsKey(key) ? _saved[key] : _prefs?.get(key);
    return value is T ? value : null;
  }

  Future<void> _save(String key, Object value, Future<bool>? Function() write) {
    _saved[key] = value;
    return _write(write);
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
