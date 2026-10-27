import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:in_app_update/in_app_update.dart';

/// What [AppUpdateService] needs from Google Play's in-app update API, so the
/// decisions can be tested without Play.
abstract class AppUpdatePlatform {
  Future<AppUpdateInfo> checkForUpdate();
  Future<AppUpdateResult> performImmediateUpdate();
  Future<AppUpdateResult> startFlexibleUpdate();
  Future<void> completeFlexibleUpdate();
}

class PlayAppUpdatePlatform implements AppUpdatePlatform {
  const PlayAppUpdatePlatform();

  @override
  Future<AppUpdateInfo> checkForUpdate() => InAppUpdate.checkForUpdate();

  @override
  Future<AppUpdateResult> performImmediateUpdate() =>
      InAppUpdate.performImmediateUpdate();

  @override
  Future<AppUpdateResult> startFlexibleUpdate() =>
      InAppUpdate.startFlexibleUpdate();

  @override
  Future<void> completeFlexibleUpdate() => InAppUpdate.completeFlexibleUpdate();
}

/// Play's in-app update exists only in Android builds installed from Play.
bool get platformHasInAppUpdate => !kIsWeb && Platform.isAndroid;

/// Checks Google Play for a newer version: when the app starts, and when it
/// comes back to the foreground at most once every [checkInterval].
///
/// Updating never interrupts a room. Installing restarts the app without a
/// leave signal, so the others would wait a minute for a reader who looks
/// like they are reconnecting, and an immediate update covers the book with
/// Play's screen. So both only happen while [isIdle] (Home, no room); a check
/// or an install that comes due in a room waits for [onIdle].
class AppUpdateService {
  static const defaultCheckInterval = Duration(hours: 4);
  static const _checkTimeout = Duration(seconds: 30);

  /// Play's priority (0-5, set per release when uploading) from which a
  /// release is installed at once instead of downloaded in the background.
  static const immediatePriority = 5;

  final AppUpdatePlatform _platform;
  final bool Function() isIdle;
  final Duration checkInterval;
  final DateTime Function() _now;

  AppUpdateService({
    required AppUpdatePlatform platform,
    required this.isIdle,
    this.checkInterval = defaultCheckInterval,
    DateTime Function()? now,
  }) : _platform = platform,
       _now = now ?? DateTime.now;

  // Process lifetime only: a cold start always checks.
  DateTime? _lastCheckAt;
  bool _checking = false;
  // A check that came due in a room; it runs on the way back Home.
  bool _checkDeferred = false;
  // Downloaded while in a room; installing restarts the app.
  bool _installDeferred = false;

  /// On app start.
  Future<void> checkOnStart() => _check(force: true);

  /// On returning to the foreground. E-readers sleep between pages, so this
  /// fires often; Play is asked at most once every [checkInterval].
  Future<void> checkOnResume() => _check(force: false);

  /// The app is back Home with no room: run what a room held back.
  Future<void> onIdle() async {
    if (!isIdle()) return;
    if (_installDeferred) {
      await _install();
    } else if (_checkDeferred) {
      await _check(force: true);
    }
  }

  Future<void> _check({required bool force}) async {
    if (_checking) return;
    final lastCheckAt = _lastCheckAt;
    if (!force &&
        lastCheckAt != null &&
        _now().difference(lastCheckAt) < checkInterval) {
      return;
    }
    if (!isIdle()) {
      // Not counted as a check: the interval starts once one actually runs.
      _checkDeferred = true;
      return;
    }
    _checking = true;
    _checkDeferred = false;
    // Set before asking, so a failing check also waits the interval instead
    // of asking Play again on every resume.
    _lastCheckAt = _now();
    try {
      final info = await _platform.checkForUpdate().timeout(_checkTimeout);
      if (info.installStatus == InstallStatus.downloaded) {
        // Downloaded earlier (a room held back the install, or the app was
        // closed before it): Play keeps it until it is installed.
        await _install();
        return;
      }
      if (info.updateAvailability != UpdateAvailability.updateAvailable) {
        return;
      }
      // The room may have started while Play was answering.
      if (!isIdle()) {
        _checkDeferred = true;
        return;
      }
      if (info.immediateUpdateAllowed &&
          info.updatePriority >= immediatePriority) {
        await _platform.performImmediateUpdate();
      } else if (info.flexibleUpdateAllowed) {
        // Play asks the user, then downloads in the background; the user can
        // walk into a room meanwhile.
        final result = await _platform.startFlexibleUpdate();
        if (result == AppUpdateResult.success) await _install();
      }
    } catch (error) {
      // Not installed from Play, no Play services, offline: nothing to do.
      debugPrint('App update check skipped: $error');
    } finally {
      _checking = false;
    }
  }

  Future<void> _install() async {
    if (!isIdle()) {
      _installDeferred = true;
      return;
    }
    _installDeferred = false;
    try {
      await _platform.completeFlexibleUpdate();
    } catch (error) {
      debugPrint('App update install failed: $error');
    }
  }
}
