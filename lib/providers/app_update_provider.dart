import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../router/app_router.dart';
import '../services/app_update_service.dart';
import 'room_provider.dart';

/// Null where Play's in-app update does not exist (iOS, desktop, web).
final appUpdateServiceProvider = Provider<AppUpdateService?>((ref) {
  if (!platformHasInAppUpdate) return null;
  return AppUpdateService(
    platform: const PlayAppUpdatePlatform(),
    isIdle: () => isIdleForUpdate(
      AppRouter.router,
      inRoom: ref.read(roomProvider).currentRoom != null,
    ),
  );
});

/// Updating (Play's full-screen update, or the restart that installs one)
/// only on Home with no room. The TXT tool and its preview are not idle
/// either: a restart would throw away a conversion that is not saved yet.
///
/// Home is the route named `home`, not a path written here: every update
/// waits for Home, so a Home that moved to another path would hold back every
/// update, silently.
bool isIdleForUpdate(GoRouter router, {required bool inRoom}) =>
    !inRoom && topLocation(router) == router.namedLocation('home');

/// The path of the page on top, including one opened with `push` (Home
/// pushes the TXT tool). `currentConfiguration.uri` leaves pushed pages out,
/// so it still reads Home while the TXT tool is open.
String topLocation(GoRouter router) {
  if (router.routerDelegate.currentConfiguration.isEmpty) return '';
  return router.state.uri.path;
}

/// Checks once the first page is up, and runs whatever a room held back each
/// time [router] moves (back Home). Returns the function that stops it.
///
/// Not checked from `initState`: the router has no page until the app is
/// built, and with no page the check would be held back for Home, so the
/// start-up check would hang on the router telling it the first page.
VoidCallback startUpdateChecks(GoRouter router, AppUpdateService updates) {
  void onRouteChanged() => unawaited(updates.onIdle());
  router.routerDelegate.addListener(onRouteChanged);
  WidgetsBinding.instance.addPostFrameCallback(
    (_) => unawaited(updates.checkOnStart()),
  );
  return () => router.routerDelegate.removeListener(onRouteChanged);
}
