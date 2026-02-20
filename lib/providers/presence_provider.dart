import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/realtime_service.dart';

final realtimeServiceProvider = Provider<RealtimeService>((ref) {
  final service = RealtimeService();
  ref.onDispose(() => service.dispose());
  return service;
});

final presenceProvider =
    StateNotifierProvider<PresenceNotifier, PresenceState>((ref) {
  final realtimeService = ref.read(realtimeServiceProvider);
  return PresenceNotifier(realtimeService);
});

class PresenceState {
  final List<Map<String, dynamic>> onlineUsers;
  final bool isConnected;

  const PresenceState({
    this.onlineUsers = const [],
    this.isConnected = false,
  });

  int get onlineCount => onlineUsers.length;

  List<String> get onlineUserIds =>
      onlineUsers
          .map((u) => u['user_id'] as String?)
          .whereType<String>()
          .toList();

  PresenceState copyWith({
    List<Map<String, dynamic>>? onlineUsers,
    bool? isConnected,
  }) {
    return PresenceState(
      onlineUsers: onlineUsers ?? this.onlineUsers,
      isConnected: isConnected ?? this.isConnected,
    );
  }
}

class PresenceNotifier extends StateNotifier<PresenceState> {
  final RealtimeService _realtimeService;
  StreamSubscription? _subscription;

  // Store current user's info so updateHasBook can re-track correctly
  String? _currentUserId;
  String? _currentNickname;
  int _currentAvatarColorIndex = 0;

  PresenceNotifier(this._realtimeService) : super(const PresenceState());

  void joinRoom({
    required String roomCode,
    required String userId,
    required String nickname,
    required int avatarColorIndex,
    bool hasBook = false,
  }) {
    _currentUserId = userId;
    _currentNickname = nickname;
    _currentAvatarColorIndex = avatarColorIndex;

    _realtimeService.joinRoom(
      roomCode: roomCode,
      userId: userId,
      nickname: nickname,
      avatarColorIndex: avatarColorIndex,
      hasBook: hasBook,
    );

    _subscription?.cancel();
    _subscription = _realtimeService.presenceStream.listen((event) {
      final users = _realtimeService.getOnlineUsers();
      state = state.copyWith(
        onlineUsers: users,
        isConnected: true,
      );
    });

    state = state.copyWith(isConnected: true);
  }

  Future<void> updateHasBook(bool hasBook) async {
    if (_currentUserId == null) return;
    await _realtimeService.updatePresence(
      userId: _currentUserId!,
      nickname: _currentNickname ?? '',
      avatarColorIndex: _currentAvatarColorIndex,
      hasBook: hasBook,
    );
  }

  Future<void> leaveRoom() async {
    _subscription?.cancel();
    _subscription = null;
    _currentUserId = null;
    _currentNickname = null;
    _currentAvatarColorIndex = 0;
    await _realtimeService.leaveRoom();
    state = const PresenceState();
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }
}
