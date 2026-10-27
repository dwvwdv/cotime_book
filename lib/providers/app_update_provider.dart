import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../router/app_router.dart';
import '../services/app_update_service.dart';
import 'room_provider.dart';

/// Null where Play's in-app update does not exist (iOS, desktop, web).
final appUpdateServiceProvider = Provider<AppUpdateService?>((ref) {
  if (!platformHasInAppUpdate) return null;
  return AppUpdateService(
    platform: const PlayAppUpdatePlatform(),
    isIdle: () => isIdleForUpdate(
      location: AppRouter.router.routerDelegate.currentConfiguration.uri.path,
      inRoom: ref.read(roomProvider).currentRoom != null,
    ),
  );
});

/// Updating (Play's full-screen update, or the restart that installs one)
/// only on Home with no room. The TXT tool and its preview are not idle
/// either: a restart would throw away a conversion that is not saved yet.
bool isIdleForUpdate({required String location, required bool inRoom}) =>
    location == '/' && !inRoom;
