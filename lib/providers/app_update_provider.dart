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
      location: topLocation(AppRouter.router),
      inRoom: ref.read(roomProvider).currentRoom != null,
    ),
  );
});

/// Updating (Play's full-screen update, or the restart that installs one)
/// only on Home with no room. The TXT tool and its preview are not idle
/// either: a restart would throw away a conversion that is not saved yet.
bool isIdleForUpdate({required String location, required bool inRoom}) =>
    location == '/' && !inRoom;

/// The path of the page on top, including one opened with `push` (Home
/// pushes the TXT tool). `currentConfiguration.uri` leaves pushed pages out,
/// so it still reads Home while the TXT tool is open.
String topLocation(GoRouter router) {
  if (router.routerDelegate.currentConfiguration.isEmpty) return '';
  return router.state.uri.path;
}
