import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/local_store.dart';
import '../services/supabase_service.dart';
import 'local_store_provider.dart';

final authProvider = StateNotifierProvider<AuthNotifier, AuthState>((ref) {
  return AuthNotifier(ref.read(localStoreProvider));
});

class AuthState {
  final String? userId;
  final String nickname;
  final bool isLoading;
  final String? error;

  const AuthState({
    this.userId,
    this.nickname = '',
    this.isLoading = false,
    this.error,
  });

  bool get isAuthenticated => userId != null;

  AuthState copyWith({
    String? userId,
    String? nickname,
    bool? isLoading,
    String? error,
  }) {
    return AuthState(
      userId: userId ?? this.userId,
      nickname: nickname ?? this.nickname,
      isLoading: isLoading ?? this.isLoading,
      error: error,
    );
  }
}

class AuthNotifier extends StateNotifier<AuthState> {
  final LocalStore _store;

  // The nickname is the only part of the identity a person types, and the
  // anonymous session already survives a restart. Asking for it again on
  // every launch made the app feel like it had forgotten them.
  AuthNotifier([LocalStore? store]) : this._(store ?? LocalStore());

  AuthNotifier._(LocalStore store)
    : _store = store,
      super(AuthState(nickname: store.nickname));

  Future<void> signInAnonymously() async {
    state = state.copyWith(isLoading: true, error: null);
    try {
      await SupabaseService.signInAnonymously();
      state = state.copyWith(
        userId: SupabaseService.currentUserId,
        isLoading: false,
      );
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: e.toString(),
      );
    }
  }

  void setNickname(String nickname) {
    state = state.copyWith(nickname: nickname);
    _store.saveNickname(nickname);
  }

  Future<void> checkExistingSession() async {
    final userId = SupabaseService.currentUserId;
    if (userId != null) {
      state = state.copyWith(userId: userId);
    }
  }
}
