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

  /// Keeps [error] unless a new one is given or [clearError] is set (GH-30).
  /// Typing a nickname used to erase a failed sign-in's message while the app
  /// was still not connected.
  AuthState copyWith({
    String? userId,
    String? nickname,
    bool? isLoading,
    String? error,
    bool clearError = false,
  }) {
    return AuthState(
      userId: userId ?? this.userId,
      nickname: nickname ?? this.nickname,
      isLoading: isLoading ?? this.isLoading,
      error: clearError ? null : (error ?? this.error),
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
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      await SupabaseService.signInAnonymously();
      state = state.copyWith(
        userId: SupabaseService.currentUserId,
        isLoading: false,
        clearError: true,
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
      // A session is a successful sign-in, so an earlier failure is moot.
      state = state.copyWith(userId: userId, clearError: true);
    }
  }
}
