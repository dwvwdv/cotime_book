import 'package:cotime_book/providers/auth_provider.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // Supabase is not initialized under test, so signing in fails the way it
  // does on a device with no network.
  test('a failed sign-in stays reported while the nickname is set', () async {
    // GH-30: entering a room signs in and then saves the nickname. Saving it
    // used to erase the sign-in error although the app was still offline.
    final auth = AuthNotifier();
    addTearDown(auth.dispose);

    await auth.signInAnonymously();
    expect(auth.state.isAuthenticated, isFalse);
    final error = auth.state.error;
    expect(error, isNotNull);

    auth.setNickname('Alice');
    expect(auth.state.nickname, 'Alice');
    expect(auth.state.error, error);
  });

  test('trying to sign in again starts without the old error', () async {
    final auth = AuthNotifier();
    addTearDown(auth.dispose);

    await auth.signInAnonymously();
    final retry = auth.signInAnonymously();
    expect(auth.state.isLoading, isTrue);
    expect(auth.state.error, isNull);
    await retry;
  });
}
