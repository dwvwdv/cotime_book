import 'dart:math';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/member_removal.dart';
import '../models/room.dart';
import '../models/room_member.dart';
import 'supabase_service.dart';
import '../l10n/l10n.dart';

class RoomSessionRevokedException implements Exception {
  final String? _message;

  /// Without a [message], says the membership is inactive or has expired.
  const RoomSessionRevokedException([this._message]);

  String get message => _message ?? appStrings.membershipInactive;

  @override
  String toString() => message;
}

class RoomSessionChangedException implements Exception {
  final String roomId;

  const RoomSessionChangedException(this.roomId);

  @override
  String toString() => appStrings.roomStateChanged;
}

/// The code no longer names a room anyone can enter: it was never issued, or
/// the room has closed. Codes are reserved forever, so this is permanent.
class RoomNotFoundException implements Exception {
  final String code;

  const RoomNotFoundException(this.code);

  @override
  String toString() => appStrings.roomNoLongerAvailableCode(code);
}

class RoomRevisionConflictException implements Exception {
  final Room currentRoom;

  const RoomRevisionConflictException(this.currentRoom);

  @override
  String toString() => appStrings.roomUpdatedByAnotherClient;
}

/// The `rooms` columns written when [bookHash] becomes the room's book.
///
/// The library path is left out when there is none rather than written as
/// null: the database clears a path the hash no longer matches on its own
/// (`clear_stale_room_library_path`), and leaving the column out keeps
/// sharing working against a database that does not have it yet (GH-28).
Map<String, dynamic> roomBookUpdate({
  required String bookTitle,
  required String bookHash,
  String? libraryPath,
}) => {
  'current_book_title': bookTitle,
  'current_book_hash': bookHash,
  if (libraryPath != null) 'current_book_library_path': libraryPath,
};

class RoomService {
  SupabaseQuerySchema get _database => SupabaseService.database;

  Future<Room> createRoom({required String nickname}) async {
    if (SupabaseService.currentUserId == null) {
      throw Exception(appStrings.notAuthenticated);
    }

    final roomData = await _database.rpc('create_room', params: {
      'p_nickname': nickname,
      'p_avatar_color_index': Random.secure().nextInt(8),
    }).single();

    return Room.fromJson(roomData);
  }

  Future<Room> joinRoom({
    required String code,
    required String nickname,
  }) async {
    if (SupabaseService.currentUserId == null) {
      throw Exception(appStrings.notAuthenticated);
    }

    try {
      final roomData = await _database.rpc('join_room', params: {
        'p_code': code.toUpperCase(),
        'p_nickname': nickname,
        'p_avatar_color_index': Random.secure().nextInt(8),
      }).single();

      return Room.fromJson(roomData);
    } on PostgrestException catch (error) {
      if (error.code == 'P0002') {
        throw RoomNotFoundException(code.toUpperCase());
      }
      rethrow;
    }
  }

  /// The codes among [codes] this account can still go back to: rooms it has
  /// been in that have not been deleted, whether open or closed.
  Future<Set<String>> availableRoomCodes(List<String> codes) async {
    final result = await _database.rpc(
      'available_room_codes',
      params: {'p_codes': codes},
    );
    return {for (final code in result as List) code as String};
  }

  Future<List<RoomMember>> getRoomMembers(String roomId) async {
    final data = await _database
        .from('room_members')
        .select()
        .eq('room_id', roomId)
        .order('joined_at');

    return data.map((json) => RoomMember.fromJson(json)).toList();
  }

  Future<void> updateMemberBookStatus({
    required String roomId,
    required String userId,
    required bool hasBook,
  }) async {
    try {
      final updatedMember = await _database
          .from('room_members')
          .update({'has_book': hasBook})
          .eq('room_id', roomId)
          .eq('user_id', userId)
          .select('id')
          .maybeSingle();

      if (updatedMember == null) {
        throw const RoomSessionRevokedException();
      }
    } on PostgrestException catch (error) {
      if (error.code == '42501' || error.code == 'P0002') {
        throw const RoomSessionRevokedException();
      }
      rethrow;
    }
  }

  Future<Room> updateRoomBook({
    required String roomId,
    required String bookTitle,
    required String bookHash,
    required int expectedRevision,
    String? libraryPath,
  }) async {
    try {
      final roomData = await _database
          .from('rooms')
          .update(
            roomBookUpdate(
              bookTitle: bookTitle,
              bookHash: bookHash,
              libraryPath: libraryPath,
            ),
          )
          .eq('id', roomId)
          .eq('revision', expectedRevision)
          .select()
          .maybeSingle();

      if (roomData == null) {
        await _throwRoomUpdateFailure(roomId);
      }

      return Room.fromJson(roomData);
    } on PostgrestException catch (error) {
      if (error.code == '42501' || error.code == 'P0002') {
        throw const RoomSessionRevokedException();
      }
      rethrow;
    }
  }

  Future<Room> updateRoomCfi({
    required String roomId,
    required String cfi,
    required int expectedRevision,
  }) async {
    try {
      final roomData = await _database
          .from('rooms')
          .update({'current_cfi': cfi})
          .eq('id', roomId)
          .eq('revision', expectedRevision)
          .select()
          .maybeSingle();
      if (roomData == null) {
        await _throwRoomUpdateFailure(roomId);
      }
      return Room.fromJson(roomData);
    } on PostgrestException catch (error) {
      if (error.code == '42501' || error.code == 'P0002') {
        throw const RoomSessionRevokedException();
      }
      rethrow;
    }
  }

  /// Host only. [textSize] null keeps the size the room has.
  Future<Room> setRoomTextSize({
    required String roomId,
    required bool locked,
    int? textSize,
  }) async {
    try {
      final roomData = await _database.rpc(
        'set_room_text_size',
        params: {
          'p_room_id': roomId,
          'p_locked': locked,
          'p_text_size': textSize,
        },
      ).single();
      return Room.fromJson(roomData);
    } on PostgrestException catch (error) {
      if (error.code == '42501' || error.code == 'P0002') {
        throw const RoomSessionRevokedException();
      }
      rethrow;
    }
  }

  /// Votes [targetUserId] out of the room; the database counts the votes.
  Future<MemberRemovalVote> voteToRemoveMember({
    required String roomId,
    required String targetUserId,
  }) async {
    try {
      final result = await _database.rpc(
        'vote_remove_member',
        params: {'p_room_id': roomId, 'p_target_user_id': targetUserId},
      );
      return MemberRemovalVote.fromJson(
        Map<String, dynamic>.from(result as Map),
      );
    } on PostgrestException catch (error) {
      if (error.code == '42501' || error.code == 'P0002') {
        throw const RoomSessionRevokedException();
      }
      rethrow;
    }
  }

  Future<Never> _throwRoomUpdateFailure(String roomId) async {
    final currentRoom = await getRoom(roomId);
    if (currentRoom == null) {
      throw const RoomSessionRevokedException();
    }
    throw RoomRevisionConflictException(currentRoom);
  }

  Future<Map<String, dynamic>> leaveRoom({required String roomId}) async {
    final result = await _database.rpc(
      'leave_room',
      params: {'p_room_id': roomId},
    );
    return Map<String, dynamic>.from(result as Map);
  }

  Future<Room> heartbeatRoom(String roomId) async {
    try {
      final roomData = await _database.rpc(
        'heartbeat_room',
        params: {'p_room_id': roomId},
      ).single();

      return Room.fromJson(roomData);
    } on PostgrestException catch (error) {
      if (error.code == '42501' || error.code == 'P0002') {
        throw const RoomSessionRevokedException();
      }
      rethrow;
    }
  }

  Future<Room?> getRoom(String roomId) async {
    final data = await _database
        .from('rooms')
        .select()
        .eq('id', roomId)
        .maybeSingle();

    return data != null ? Room.fromJson(data) : null;
  }
}
