import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'config/app_constants.dart';
import 'config/supabase_config.dart';
import 'config/theme.dart';
import 'providers/ads_provider.dart';
import 'providers/app_update_provider.dart';
import 'providers/auth_provider.dart';
import 'providers/presence_provider.dart';
import 'providers/room_provider.dart';
import 'router/app_router.dart';

class CoTimeBookApp extends ConsumerStatefulWidget {
  const CoTimeBookApp({super.key});

  @override
  ConsumerState<CoTimeBookApp> createState() => _CoTimeBookAppState();
}

class _CoTimeBookAppState extends ConsumerState<CoTimeBookApp>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Loads the first ads now, so the first one due is usually ready.
    ref.read(pageTurnAdsProvider);
    ref.read(txtSaveAdsProvider);
    _initAuth();
    final updates = ref.read(appUpdateServiceProvider);
    if (updates != null) {
      unawaited(updates.checkOnStart());
      AppRouter.router.routerDelegate.addListener(_onMaybeIdle);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    AppRouter.router.routerDelegate.removeListener(_onMaybeIdle);
    super.dispose();
  }

  // An update held back by a room runs once the app is back Home with no
  // room; leaving clears the room and goes Home in either order.
  void _onMaybeIdle() {
    final updates = ref.read(appUpdateServiceProvider);
    if (updates != null) unawaited(updates.onIdle());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final isActive = appActivityFor(state);
    if (isActive == null) return;
    // Backgrounding is not leaving a room. Presence becomes transiently
    // unavailable and the database lease stops renewing until resume.
    unawaited(_updateAppLifecycle(isActive));
  }

  Future<void> _updateAppLifecycle(bool isActive) async {
    try {
      ref.read(roomProvider.notifier).setAppActive(isActive);
    } catch (error) {
      debugPrint('Unable to update room heartbeat lifecycle: $error');
    }
    if (isActive) {
      // The socket is closed while the app sleeps (supabase_flutter does that
      // on pause, and e-readers sleep between pages). If the library's own
      // rejoin does not bring the room channel back, rebuild it.
      ref.read(realtimeServiceProvider).checkConnection();
      final updates = ref.read(appUpdateServiceProvider);
      if (updates != null) unawaited(updates.checkOnResume());
    }
    try {
      await ref.read(presenceProvider.notifier).setAppActive(isActive);
    } catch (error) {
      debugPrint('Unable to update app lifecycle Presence: $error');
    }
  }

  Future<void> _initAuth() async {
    final authNotifier = ref.read(authProvider.notifier);

    if (SupabaseConfig.isConfigured) {
      // Check for existing session first
      await authNotifier.checkExistingSession();

      // If no session, sign in anonymously
      if (!ref.read(authProvider).isAuthenticated) {
        await authNotifier.signInAnonymously();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<bool>(
      roomProvider.select((state) => state.currentRoom == null),
      (_, noRoom) {
        if (noRoom) _onMaybeIdle();
      },
    );
    return MaterialApp.router(
      title: AppConstants.appName,
      theme: AppTheme.paperTheme,
      scrollBehavior: const PaperScrollBehavior(),
      routerConfig: AppRouter.router,
      debugShowCheckedModeBanner: false,
    );
  }
}

/// Whether the room should see this app as active, or null to leave it as is.
///
/// `inactive` is a notification shade, a permission dialog, a transition: the
/// reader is still looking at the page. Treating it as leaving dropped the
/// reader out of the page-turn quorum for a moment and cancelled turns.
bool? appActivityFor(AppLifecycleState state) {
  return switch (state) {
    AppLifecycleState.inactive => null,
    AppLifecycleState.resumed => true,
    AppLifecycleState.paused ||
    AppLifecycleState.hidden ||
    AppLifecycleState.detached => false,
  };
}
