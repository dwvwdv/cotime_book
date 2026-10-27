import 'package:cotime_book/providers/app_update_provider.dart';
import 'package:cotime_book/services/app_update_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:in_app_update/in_app_update.dart';

class FakePlay implements AppUpdatePlatform {
  UpdateAvailability availability = UpdateAvailability.updateNotAvailable;
  InstallStatus installStatus = InstallStatus.unknown;
  int priority = 0;
  bool immediateAllowed = true;
  bool failCheck = false;
  AppUpdateResult flexibleResult = AppUpdateResult.success;

  int checks = 0;
  int immediateUpdates = 0;
  int flexibleDownloads = 0;
  int installs = 0;

  /// Runs while Play is answering a check, e.g. to walk into a room.
  void Function()? duringCheck;

  void offer({int priority = 0}) {
    availability = UpdateAvailability.updateAvailable;
    this.priority = priority;
  }

  @override
  Future<AppUpdateInfo> checkForUpdate() async {
    checks++;
    duringCheck?.call();
    if (failCheck) throw Exception('ERROR_APP_NOT_OWNED');
    return AppUpdateInfo(
      updateAvailability: availability,
      immediateUpdateAllowed: immediateAllowed,
      immediateAllowedPreconditions: null,
      flexibleUpdateAllowed: true,
      flexibleAllowedPreconditions: null,
      availableVersionCode: 99,
      installStatus: installStatus,
      packageName: 'com.lazyrhythm.cotime_book',
      clientVersionStalenessDays: 1,
      updatePriority: priority,
    );
  }

  @override
  Future<AppUpdateResult> performImmediateUpdate() async {
    immediateUpdates++;
    return AppUpdateResult.success;
  }

  @override
  Future<AppUpdateResult> startFlexibleUpdate() async {
    flexibleDownloads++;
    if (flexibleResult == AppUpdateResult.success) {
      installStatus = InstallStatus.downloaded;
    }
    return flexibleResult;
  }

  @override
  Future<void> completeFlexibleUpdate() async {
    installs++;
    availability = UpdateAvailability.updateNotAvailable;
    installStatus = InstallStatus.installed;
  }
}

void main() {
  late FakePlay play;
  late DateTime now;
  late bool idle;
  late AppUpdateService service;

  setUp(() {
    play = FakePlay();
    now = DateTime(2026, 10, 27, 9);
    idle = true;
    service = AppUpdateService(
      platform: play,
      isIdle: () => idle,
      now: () => now,
    );
  });

  group('how often Play is asked', () {
    test('every start checks, and a resume waits four hours', () async {
      await service.checkOnStart();
      expect(play.checks, 1);

      now = now.add(const Duration(hours: 3, minutes: 59));
      await service.checkOnResume();
      expect(play.checks, 1);

      now = now.add(const Duration(minutes: 1));
      await service.checkOnResume();
      expect(play.checks, 2);
    });

    test('a failed check also waits four hours', () async {
      play.failCheck = true;
      await service.checkOnStart();
      now = now.add(const Duration(hours: 1));
      await service.checkOnResume();
      expect(play.checks, 1);
    });

    test('the first resume after start does not ask again', () async {
      await service.checkOnStart();
      await service.checkOnResume();
      expect(play.checks, 1);
    });
  });

  group('installing', () {
    test('a regular release downloads, then installs', () async {
      play.offer();
      await service.checkOnStart();
      expect(play.immediateUpdates, 0);
      expect(play.flexibleDownloads, 1);
      expect(play.installs, 1);
    });

    test('a priority-5 release updates at once', () async {
      play.offer(priority: 5);
      await service.checkOnStart();
      expect(play.immediateUpdates, 1);
      expect(play.flexibleDownloads, 0);
    });

    test('a priority-5 release Play will not force still downloads', () async {
      play.offer(priority: 5);
      play.immediateAllowed = false;
      await service.checkOnStart();
      expect(play.immediateUpdates, 0);
      expect(play.flexibleDownloads, 1);
    });

    test('a declined download installs nothing', () async {
      play.offer();
      play.flexibleResult = AppUpdateResult.userDeniedUpdate;
      await service.checkOnStart();
      expect(play.installs, 0);
    });

    test('a download left from last time installs on the next check', () async {
      play.offer();
      play.installStatus = InstallStatus.downloaded;
      await service.checkOnStart();
      expect(play.flexibleDownloads, 0);
      expect(play.installs, 1);
    });
  });

  group('a room is never interrupted', () {
    test('a check that comes due in a room waits for Home', () async {
      idle = false;
      play.offer(priority: 5);
      await service.checkOnStart();
      expect(play.checks, 0);
      expect(play.immediateUpdates, 0);

      idle = true;
      await service.onIdle();
      expect(play.checks, 1);
      expect(play.immediateUpdates, 1);
    });

    test('a resume in a room within four hours is not held for Home', () async {
      await service.checkOnStart();
      idle = false;
      now = now.add(const Duration(hours: 1));
      await service.checkOnResume();

      idle = true;
      await service.onIdle();
      expect(play.checks, 1);
    });

    test('walking into a room during the check holds the update', () async {
      play.offer(priority: 5);
      play.duringCheck = () => idle = false;
      await service.checkOnStart();
      expect(play.immediateUpdates, 0);
      expect(play.flexibleDownloads, 0);

      play.duringCheck = null;
      idle = true;
      await service.onIdle();
      expect(play.immediateUpdates, 1);
    });

    test('a download that finishes in a room installs back Home', () async {
      // The download runs in the background while the user joins a room.
      final fresh = FakePlay()..offer();
      var inRoom = false;
      final roomy = AppUpdateService(
        platform: _RoomDuringDownload(fresh, () => inRoom = true),
        isIdle: () => !inRoom,
        now: () => now,
      );
      await roomy.checkOnStart();
      expect(fresh.flexibleDownloads, 1);
      expect(fresh.installs, 0, reason: 'installing restarts the app');

      // Still in the room: nothing happens.
      await roomy.onIdle();
      expect(fresh.installs, 0);

      inRoom = false;
      await roomy.onIdle();
      expect(fresh.installs, 1);
    });

    test('Home with nothing held back does not ask Play', () async {
      await service.checkOnStart();
      await service.onIdle();
      expect(play.checks, 1);
    });
  });

  test('only Home with no room is idle', () {
    expect(isIdleForUpdate(location: '/', inRoom: false), isTrue);
    expect(isIdleForUpdate(location: '/', inRoom: true), isFalse);
    expect(isIdleForUpdate(location: '/lobby/ABCDEF', inRoom: true), isFalse);
    expect(isIdleForUpdate(location: '/reader/ABCDEF', inRoom: true), isFalse);
    // A conversion that is not saved yet would be lost to the restart.
    expect(isIdleForUpdate(location: '/convert', inRoom: false), isFalse);
  });
}

/// Joins a room while the flexible download is running.
class _RoomDuringDownload implements AppUpdatePlatform {
  final FakePlay play;
  final void Function() joinRoom;

  _RoomDuringDownload(this.play, this.joinRoom);

  @override
  Future<AppUpdateInfo> checkForUpdate() => play.checkForUpdate();

  @override
  Future<AppUpdateResult> performImmediateUpdate() =>
      play.performImmediateUpdate();

  @override
  Future<AppUpdateResult> startFlexibleUpdate() async {
    final result = await play.startFlexibleUpdate();
    joinRoom();
    return result;
  }

  @override
  Future<void> completeFlexibleUpdate() => play.completeFlexibleUpdate();
}
