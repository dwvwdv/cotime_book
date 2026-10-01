import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'config/supabase_config.dart';
import 'config/theme.dart';
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
    _initAuth();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
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
    return MaterialApp.router(
      title: 'CoTime Book',
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
