import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/member_removal.dart';
import '../models/room.dart';
import '../models/room_member.dart';
import '../providers/page_sync_provider.dart';
import '../providers/presence_provider.dart';
import '../services/room_service.dart';
import '../services/supabase_service.dart';

final roomServiceProvider = Provider<RoomService>((ref) => RoomService());

final roomProvider = StateNotifierProvider<RoomNotifier, RoomState>((ref) {
  final realtime = ref.read(realtimeServiceProvider);
  final notifier = RoomNotifier(
    ref.read(roomServiceProvider),
    onSessionRevoked: () async {
      await Future.wait<void>([
        ref.read(pageSyncProvider.notifier).stop(),
        ref.read(presenceProvider.notifier).leaveRoom(),
      ]);
    },
  );
  // Realtime refusing the room channel is a hint that the membership is gone,
  // not proof of it: the database decides (GH-36).
  final accessDenied = realtime.accessDeniedStream.listen((denied) async {
    final stillMember = await notifier.confirmMembershipAfterAccessDenied();
    if (stillMember) realtime.retryAfterAccessDenied(denied.generation);
  });
  ref.onDispose(accessDenied.cancel);
  return notifier;
});

class RoomState {
  final Room? currentRoom;
  final List<RoomMember> members;
  final bool isLoading;
  final String? error;

  const RoomState({
    this.currentRoom,
    this.members = const [],
    this.isLoading = false,
    this.error,
  });

  bool get isInRoom => currentRoom != null;
  bool get isHost =>
      currentRoom != null &&
      currentRoom!.hostUserId == SupabaseService.currentUserId;
  bool get allMembersHaveBook =>
      members.isNotEmpty && members.every((m) => m.hasBook);

  /// Keeps [error] unless a new one is given or [clearError] is set. Every
  /// state update used to drop the error as a side effect, so whether a
  /// message survived depended on which unrelated update happened to run next
  /// (GH-30). Clearing is now a decision made where an operation starts over
  /// or succeeds.
  RoomState copyWith({
    Room? currentRoom,
    List<RoomMember>? members,
    bool? isLoading,
    String? error,
    bool clearError = false,
  }) {
    return RoomState(
      currentRoom: currentRoom ?? this.currentRoom,
      members: members ?? this.members,
      isLoading: isLoading ?? this.isLoading,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

class RoomNotifier extends StateNotifier<RoomState> {
  static const heartbeatInterval = Duration(minutes: 5);
  static const leaveRetryDelay = Duration(milliseconds: 800);

  String? _pendingSaveCfi;
  Future<void>? _saveLoop;

  final RoomService _roomService;
  final Future<void> Function()? _onSessionRevoked;
  Timer? _heartbeatTimer;
  bool _heartbeatInFlight = false;
  bool _appIsActive = true;
  bool _revocationInProgress = false;
  int _roomSessionGeneration = 0;
  int _membersFetchGeneration = 0;
  int _appliedMembersGeneration = 0;
  List<Map<String, dynamic>> _lastPresenceUsers = const [];

  RoomNotifier(
    this._roomService, {
    Future<void> Function()? onSessionRevoked,
  }) : _onSessionRevoked = onSessionRevoked,
       super(const RoomState());

  Future<Room?> createRoom(String nickname) {
    return _enterRoom(() => _roomService.createRoom(nickname: nickname));
  }

  Future<Room?> joinRoom(String code, String nickname) {
    return _enterRoom(
      () => _roomService.joinRoom(code: code, nickname: nickname),
    );
  }

  /// Goes back to a room from the recent list.
  ///
  /// join_room reopens a closed room for anyone who was in it, so failing
  /// with [RoomNotFoundException] means the room is gone for good (deleted
  /// after 30 days closed). [gone] tells the caller the entry can be dropped,
  /// as opposed to a network error that is worth trying again.
  Future<({Room? room, bool gone})> rejoinRoom(
    String code,
    String nickname,
  ) async {
    var gone = false;
    final room = await _enterRoom(() async {
      try {
        return await _roomService.joinRoom(code: code, nickname: nickname);
      } on RoomNotFoundException {
        gone = true;
        rethrow;
      }
    });
    return (room: room, gone: gone);
  }

  Future<Room?> _enterRoom(Future<Room> Function() enter) async {
    final operationGeneration = ++_roomSessionGeneration;
    _resetMemberTracking();
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      final room = await enter();
      final members = await _roomService.getRoomMembers(room.id);
      if (_roomSessionGeneration != operationGeneration) return null;
      state = state.copyWith(
        currentRoom: room,
        members: members,
        isLoading: false,
        clearError: true,
      );
      _startHeartbeat(room.id);
      return room;
    } catch (e) {
      if (_roomSessionGeneration == operationGeneration) {
        state = state.copyWith(isLoading: false, error: e.toString());
      }
      return null;
    }
  }

  Future<void> refreshMembers({List<Map<String, dynamic>>? presenceUsers}) async {
    final room = state.currentRoom;
    if (room == null) return;
    final roomSessionGeneration = _roomSessionGeneration;
    // The database owns the roster; Presence only owns the per-member online
    // and has_book overlay. A Presence overlay applied during the await no
    // longer throws the roster away — that used to drop a member who joined
    // while this refresh was in flight, because the same listener re-applies
    // Presence on every event.
    //
    // Results are ordered against the last one *applied*, not the last one
    // started: a fetch only loses to a newer fetch that actually succeeded.
    // Two listeners now race for the same join (Presence and
    // membership_changed), so discarding an older success merely because a
    // later request had started would lose the roster entirely whenever that
    // later request failed.
    final fetchGeneration = ++_membersFetchGeneration;
    if (presenceUsers != null) _lastPresenceUsers = presenceUsers;
    try {
      final members = await _roomService.getRoomMembers(room.id);
      if (!_isCurrentRoomSession(room.id, roomSessionGeneration) ||
          fetchGeneration <= _appliedMembersGeneration) {
        return;
      }
      _appliedMembersGeneration = fetchGeneration;
      // A roster read that reached the database is as good a sign the
      // connection is back as a heartbeat is; the lobby re-reads the roster
      // every few seconds, so this is what retires a failed read's message.
      state = state.copyWith(
        members: _applyPresenceOverlay(members, _lastPresenceUsers),
        clearError: true,
      );
    } catch (error) {
      if (_isCurrentRoomSession(room.id, roomSessionGeneration) &&
          fetchGeneration > _appliedMembersGeneration) {
        state = state.copyWith(error: error.toString());
      }
    }
  }

  void updateMembersFromPresence(List<Map<String, dynamic>> onlineUsers) {
    _lastPresenceUsers = onlineUsers;
    final updatedMembers = _applyPresenceOverlay(state.members, onlineUsers);
    // Presence fires far more often than it changes anything. Rewriting state
    // with an identical roster only churns listeners and rebuilds.
    if (_membersMatch(state.members, updatedMembers)) return;
    state = state.copyWith(members: updatedMembers);
  }

  List<RoomMember> _applyPresenceOverlay(
    List<RoomMember> members,
    List<Map<String, dynamic>> onlineUsers,
  ) {
    // An empty list is a real answer, not a missing one: the channel dropped
    // and nobody is online. Skipping it would leave every cached member showing
    // as online while the lobby header reports zero, and the roster refresh
    // that would correct it needs the same network that just failed.
    final onlineById = {
      for (final user in onlineUsers)
        if (user['user_id'] is String) user['user_id'] as String: user,
    };
    return members.map((member) {
      final onlineData = onlineById[member.userId];
      return member.copyWith(
        isOnline: onlineData != null,
        hasBook: (onlineData?['has_book'] as bool?) ?? member.hasBook,
      );
    }).toList(growable: false);
  }

  bool _membersMatch(List<RoomMember> a, List<RoomMember> b) {
    if (a.length != b.length) return false;
    for (var index = 0; index < a.length; index++) {
      final left = a[index];
      final right = b[index];
      if (left.userId != right.userId ||
          left.nickname != right.nickname ||
          left.avatarColorIndex != right.avatarColorIndex ||
          left.isOnline != right.isOnline ||
          left.hasBook != right.hasBook) {
        return false;
      }
    }
    return true;
  }

  /// Called on all clients (including receiver) when book_shared broadcast arrives.
  void onBookSharedReceived({
    required String bookTitle,
    required String bookHash,
    String? libraryPath,
  }) {
    final room = state.currentRoom;
    if (room == null) return;
    state = state.copyWith(
      currentRoom: room.copyWith(
        currentBookTitle: bookTitle,
        currentBookHash: bookHash,
        // Replaced even when null: the previous book's path does not locate
        // this one.
        currentBookLibraryPath: libraryPath,
      ),
    );
  }

  /// Update DB has_book status for the current user (receiver side).
  Future<void> updateReceiverBookStatus() async {
    final room = state.currentRoom;
    final userId = SupabaseService.currentUserId;
    if (room == null || userId == null) return;
    final roomSessionGeneration = _roomSessionGeneration;
    try {
      await _roomService.updateMemberBookStatus(
        roomId: room.id,
        userId: userId,
        hasBook: true,
      );
      if (!_isCurrentRoomSession(room.id, roomSessionGeneration)) return;
      await refreshMembers();
    } on RoomSessionRevokedException catch (error) {
      await _revokeSession(room.id, error.message, roomSessionGeneration);
    } catch (error) {
      if (_isCurrentRoomSession(room.id, roomSessionGeneration)) {
        state = state.copyWith(error: error.toString());
      }
    }
  }

  /// Makes [bookHash] the room's book. Returns false when another member's
  /// book reached the room first: two shares racing each other resolve to the
  /// one that committed first, and the other device follows it instead of
  /// overwriting it on the conflict retry.
  ///
  /// [libraryPath] is where the book is in the public library, null when it
  /// is not from there. The room keeps it so members who arrive later can
  /// download the book too (GH-28).
  Future<bool> updateBookShared({
    required String bookTitle,
    required String bookHash,
    String? libraryPath,
  }) async {
    final room = state.currentRoom;
    if (room == null) return false;
    final roomSessionGeneration = _roomSessionGeneration;

    var writeOrigin = room;
    Room? updatedRoom;
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        updatedRoom = await _roomService.updateRoomBook(
          roomId: room.id,
          bookTitle: bookTitle,
          bookHash: bookHash,
          expectedRevision: writeOrigin.revision,
          libraryPath: libraryPath,
        );
        break;
      } on RoomRevisionConflictException catch (error) {
        if (!_isCurrentRoomSession(room.id, roomSessionGeneration)) {
          throw RoomSessionChangedException(room.id);
        }
        final committedBook = error.currentRoom.currentBookHash;
        final sharedMeanwhile =
            committedBook != writeOrigin.currentBookHash &&
            committedBook != bookHash;
        _applyRoomUpdate(
          error.currentRoom,
          originRoom: writeOrigin,
          roomSessionGeneration: roomSessionGeneration,
        );
        // Retrying would put this book over one the room may already be
        // reading. Only revisions bumped by anything else are retried.
        if (sharedMeanwhile) return false;
        writeOrigin = state.currentRoom!;
        if (attempt == 1) rethrow;
      } on RoomSessionRevokedException catch (error) {
        await _revokeSession(room.id, error.message, roomSessionGeneration);
        rethrow;
      }
    }
    if (updatedRoom == null) {
      throw StateError('Room book update did not complete');
    }
    if (!_isCurrentRoomSession(room.id, roomSessionGeneration)) {
      throw RoomSessionChangedException(room.id);
    }

    final userId = SupabaseService.currentUserId;
    if (userId != null) {
      try {
        await _roomService.updateMemberBookStatus(
          roomId: room.id,
          userId: userId,
          hasBook: true,
        );
      } on RoomSessionRevokedException catch (error) {
        await _revokeSession(room.id, error.message, roomSessionGeneration);
        rethrow;
      }
    }
    if (!_isCurrentRoomSession(room.id, roomSessionGeneration)) {
      throw RoomSessionChangedException(room.id);
    }

    _applyRoomUpdate(
      updatedRoom,
      originRoom: writeOrigin,
      roomSessionGeneration: roomSessionGeneration,
    );

    await refreshMembers();
    return true;
  }

  /// Fetch the latest room data from DB (e.g. to get updated CFI on re-entry).
  ///
  /// [quiet] is for background re-reads: a failed one says nothing, since
  /// [RoomState.error] stays up until something clears it (GH-30) and the
  /// next re-read is only seconds away.
  Future<void> refreshRoom({bool quiet = false}) async {
    await refreshRoomAndGet(quiet: quiet);
  }

  /// Fetch and return an authoritative room snapshot when recovery depends on
  /// knowing whether the read completed for the current room session.
  Future<Room?> refreshRoomAndGet({bool quiet = false}) async {
    final room = state.currentRoom;
    if (room == null) return null;
    final roomSessionGeneration = _roomSessionGeneration;
    try {
      final updated = await _roomService.getRoom(room.id);
      if (updated == null) {
        if (_isCurrentRoomSession(room.id, roomSessionGeneration)) {
          await _revokeSession(
            room.id,
            'This room membership is inactive or has expired.',
            roomSessionGeneration,
          );
        }
        return null;
      }
      final applied = _applyRoomUpdate(
        updated,
        originRoom: room,
        roomSessionGeneration: roomSessionGeneration,
      );
      if (applied ||
          (_isCurrentRoomSession(room.id, roomSessionGeneration) &&
              state.currentRoom!.revision > updated.revision)) {
        return state.currentRoom;
      }
    } catch (error) {
      if (!quiet && _isCurrentRoomSession(room.id, roomSessionGeneration)) {
        state = state.copyWith(error: error.toString());
      }
    }
    return null;
  }

  /// Host only: who sets the room's text size, and the size while the host
  /// does. Returns false when the change did not happen; the room is then
  /// re-read, since the refusal usually means someone else is host now.
  Future<bool> setRoomTextSize({required bool locked, int? textSize}) async {
    final room = state.currentRoom;
    if (room == null) return false;
    final roomSessionGeneration = _roomSessionGeneration;
    try {
      final updated = await _roomService.setRoomTextSize(
        roomId: room.id,
        locked: locked,
        textSize: textSize,
      );
      _applyRoomUpdate(
        updated,
        originRoom: room,
        roomSessionGeneration: roomSessionGeneration,
      );
      return _isCurrentRoomSession(room.id, roomSessionGeneration);
    } on RoomSessionRevokedException catch (error) {
      await _revokeSession(room.id, error.message, roomSessionGeneration);
      return false;
    } catch (_) {
      if (_isCurrentRoomSession(room.id, roomSessionGeneration)) {
        await refreshRoom(quiet: true);
      }
      return false;
    }
  }

  /// Votes [targetUserId] out of the room (someone who is gone and holds
  /// everyone up). Returns null when this device is no longer in the room
  /// itself, or left it meanwhile; other failures are thrown for the caller
  /// to report.
  Future<MemberRemovalVote?> voteToRemoveMember(String targetUserId) async {
    final room = state.currentRoom;
    if (room == null) return null;
    final roomSessionGeneration = _roomSessionGeneration;
    try {
      final result = await _roomService.voteToRemoveMember(
        roomId: room.id,
        targetUserId: targetUserId,
      );
      if (!_isCurrentRoomSession(room.id, roomSessionGeneration)) return null;
      if (result.status != MemberRemovalStatus.voting) {
        // The roster changed (or was already behind); the lobby would only
        // catch up on its next periodic read. The room too: a removed host
        // hands the room over, and the reader only re-reads it every 30
        // seconds.
        unawaited(refreshMembers());
        unawaited(refreshRoom(quiet: true));
      }
      return result;
    } on RoomSessionRevokedException catch (error) {
      await _revokeSession(room.id, error.message, roomSessionGeneration);
      return null;
    }
  }

  Future<void> updateCfi(String cfi) async {
    final room = state.currentRoom;
    if (room == null) return;

    await updateCfiForRoom(roomId: room.id, cfi: cfi);
  }

  Future<void> updateCfiForRoom({
    required String roomId,
    required String cfi,
  }) async {
    if (state.currentRoom?.id != roomId || state.isLoading) {
      throw RoomSessionChangedException(roomId);
    }
    final roomSessionGeneration = _roomSessionGeneration;
    final originRoom = state.currentRoom!;

    var writeOrigin = originRoom;
    Room? updatedRoom;
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        updatedRoom = await _roomService.updateRoomCfi(
          roomId: roomId,
          cfi: cfi,
          expectedRevision: writeOrigin.revision,
        );
        break;
      } on RoomRevisionConflictException catch (error) {
        if (_roomSessionGeneration != roomSessionGeneration ||
            state.currentRoom?.id != roomId) {
          throw RoomSessionChangedException(roomId);
        }
        _applyRoomUpdate(
          error.currentRoom,
          originRoom: writeOrigin,
          roomSessionGeneration: roomSessionGeneration,
        );
        writeOrigin = state.currentRoom!;
        if (attempt == 1) rethrow;
      } on RoomSessionRevokedException catch (error) {
        await _revokeSession(roomId, error.message, roomSessionGeneration);
        rethrow;
      }
    }
    if (updatedRoom == null) {
      throw StateError('Room position update did not complete');
    }
    if (_roomSessionGeneration != roomSessionGeneration ||
        state.currentRoom?.id != roomId) {
      throw RoomSessionChangedException(roomId);
    }
    _applyRoomUpdate(
      updatedRoom,
      originRoom: writeOrigin,
      roomSessionGeneration: roomSessionGeneration,
      clearError: true,
    );
  }

  /// Persists the room's page for whoever opens the book next.
  ///
  /// Best effort by design: live readers converge through Presence, so a
  /// failed write must never hold up or undo a page turn. A revoked membership
  /// still tears the session down inside [updateCfiForRoom].
  ///
  /// Saves are serialized and coalesced to the latest page. Two overlapping
  /// writes used to race: the newer one committed first, and the older one's
  /// revision-conflict retry then wrote the older page over it.
  Future<void> saveReadingPosition(String cfi) {
    if (state.currentRoom == null || cfi.isEmpty) return Future.value();
    _pendingSaveCfi = cfi;
    return _saveLoop ??= _drainPositionSaves().whenComplete(
      () => _saveLoop = null,
    );
  }

  Future<void> _drainPositionSaves() async {
    while (true) {
      final cfi = _pendingSaveCfi;
      final room = state.currentRoom;
      _pendingSaveCfi = null;
      if (cfi == null || room == null) return;
      try {
        await updateCfiForRoom(roomId: room.id, cfi: cfi);
      } catch (_) {
        // Best effort; the next save (or live Presence) supersedes it.
      }
    }
  }

  Future<void> heartbeat() async {
    final room = state.currentRoom;
    if (room == null) return;

    await _sendHeartbeat(room.id, rethrowError: true);
  }

  void setAppActive(bool isActive) {
    _appIsActive = isActive;
    if (!isActive) {
      _heartbeatTimer?.cancel();
      _heartbeatTimer = null;
      return;
    }

    final roomId = state.currentRoom?.id;
    if (roomId != null) {
      _startHeartbeat(roomId, sendImmediately: true);
    }
  }

  void _startHeartbeat(String roomId, {bool sendImmediately = false}) {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    if (!_appIsActive) return;

    if (sendImmediately) {
      unawaited(_sendHeartbeat(roomId));
    }
    _heartbeatTimer = Timer.periodic(heartbeatInterval, (_) {
      unawaited(_sendHeartbeat(roomId));
    });
  }

  Future<void> _sendHeartbeat(
    String roomId, {
    bool rethrowError = false,
  }) async {
    if (_heartbeatInFlight ||
        !_appIsActive ||
        state.currentRoom?.id != roomId) {
      return;
    }

    final roomSessionGeneration = _roomSessionGeneration;
    final originRoom = state.currentRoom!;
    _heartbeatInFlight = true;
    try {
      final updatedRoom = await _roomService.heartbeatRoom(roomId);
      _applyRoomUpdate(
        updatedRoom,
        originRoom: originRoom,
        roomSessionGeneration: roomSessionGeneration,
        clearError: true,
      );
    } on RoomSessionRevokedException catch (error) {
      await _revokeSession(roomId, error.message, roomSessionGeneration);
      if (rethrowError) rethrow;
    } catch (error) {
      if (_isCurrentRoomSession(roomId, roomSessionGeneration)) {
        state = state.copyWith(error: error.toString());
      }
      if (rethrowError) rethrow;
    } finally {
      _heartbeatInFlight = false;
    }
  }

  /// Shown when this device finds it is no longer in the room it was in.
  static const removedFromRoomMessage =
      'You are no longer in this room. It may have closed, or you left it on '
      'another device.';

  /// Shown when the others in the room voted this device out.
  static const removedByVoteMessage =
      'The other readers removed you from this room. You can join again '
      'with the room code.';

  /// Realtime refused this room's channel. That happens when the membership
  /// is gone — left on another device, evicted after a long sleep, the room
  /// closed — but the database is the authority on membership, so ask it.
  ///
  /// Returns whether this device is still in the room, i.e. whether the
  /// channel is worth trying again. A failed read counts as still in: a
  /// network error is no reason to throw the reader out of the room.
  Future<bool> confirmMembershipAfterAccessDenied() =>
      _confirmMembership(removedFromRoomMessage);

  /// Another member said the room voted this device out. Only a hint, like a
  /// refused channel: the database decides.
  Future<bool> confirmMembershipAfterRemoval() =>
      _confirmMembership(removedByVoteMessage);

  Future<bool> _confirmMembership(String goneMessage) async {
    final room = state.currentRoom;
    if (room == null) return false;
    final roomSessionGeneration = _roomSessionGeneration;
    final Room? current;
    try {
      current = await _roomService.getRoom(room.id);
    } catch (_) {
      return mounted && _isCurrentRoomSession(room.id, roomSessionGeneration);
    }
    // Left or replaced meanwhile: whoever did that owns the channel now.
    if (!mounted || !_isCurrentRoomSession(room.id, roomSessionGeneration)) {
      return false;
    }
    if (current == null) {
      await _revokeSession(room.id, goneMessage, roomSessionGeneration);
      return false;
    }
    _applyRoomUpdate(
      current,
      originRoom: room,
      roomSessionGeneration: roomSessionGeneration,
    );
    return true;
  }

  /// [roomSessionGeneration] is the session the refusal was for. A request
  /// sent before a leave can come back refused after the leave RPC ran; that
  /// is the leave itself, not a revocation to report.
  Future<void> _revokeSession(
    String roomId,
    String reason,
    int roomSessionGeneration,
  ) async {
    if (_revocationInProgress ||
        !_isCurrentRoomSession(roomId, roomSessionGeneration)) {
      return;
    }
    _revocationInProgress = true;
    _roomSessionGeneration++;
    _resetMemberTracking();
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    state = RoomState(error: reason);
    try {
      await _onSessionRevoked?.call();
    } catch (_) {
      // The authoritative room state is already revoked. Best-effort transport
      // cleanup must not turn a periodic heartbeat into an unhandled error.
    } finally {
      _revocationInProgress = false;
    }
  }

  Future<void> leaveRoom() async {
    final room = state.currentRoom;
    final leavingGeneration = ++_roomSessionGeneration;
    _resetMemberTracking();
    if (room == null) {
      _heartbeatTimer?.cancel();
      _heartbeatTimer = null;
      state = const RoomState();
      return;
    }

    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      try {
        await _roomService.leaveRoom(roomId: room.id);
      } catch (_) {
        // A failed leave leaves this member in everyone else's list until the
        // server evicts them half an hour later. One retry covers a dropped
        // request; leaving is idempotent, so a lost response is harmless.
        await Future<void>.delayed(leaveRetryDelay);
        await _roomService.leaveRoom(roomId: room.id);
      }
    } finally {
      if (_roomSessionGeneration == leavingGeneration) {
        state = const RoomState();
      }
    }
  }

  /// Drops the Presence overlay and invalidates any in-flight roster fetch so
  /// a previous room cannot bleed into the next one.
  void _resetMemberTracking() {
    _membersFetchGeneration++;
    _appliedMembersGeneration = _membersFetchGeneration;
    _lastPresenceUsers = const [];
  }

  bool _isCurrentRoomSession(String roomId, int roomSessionGeneration) {
    return _roomSessionGeneration == roomSessionGeneration &&
        state.currentRoom?.id == roomId;
  }

  bool _applyRoomUpdate(
    Room updatedRoom, {
    required Room originRoom,
    required int roomSessionGeneration,
    bool clearError = false,
  }) {
    if (!_isCurrentRoomSession(updatedRoom.id, roomSessionGeneration)) {
      return false;
    }
    final currentRoom = state.currentRoom!;
    final isNewer = updatedRoom.revision > currentRoom.revision;
    final isUnchangedSnapshot =
        updatedRoom.revision == currentRoom.revision &&
        identical(currentRoom, originRoom);
    if (!isNewer && !isUnchangedSnapshot) return false;

    state = state.copyWith(currentRoom: updatedRoom, clearError: clearError);
    return true;
  }

  void clearError() {
    state = state.copyWith(clearError: true);
  }

  @override
  void dispose() {
    _heartbeatTimer?.cancel();
    super.dispose();
  }
}
