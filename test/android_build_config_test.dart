import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Reads `<key> = <literal int>` from the app's build.gradle. A value taken
/// from `flutter.*` is rejected: Flutter 3.32's defaults are below what Google
/// Play accepts, so the build file has to pin each level itself.
int _sdkLevel(String key) {
  final gradle = File('android/app/build.gradle').readAsStringSync();
  final match =
      RegExp('^\\s*$key\\s*=\\s*(\\S+)', multiLine: true).firstMatch(gradle);
  expect(match, isNotNull, reason: '$key must be set in build.gradle');
  final level = int.tryParse(match!.group(1)!);
  expect(level, isNotNull,
      reason: '$key must be a literal, not ${match.group(1)}');
  return level!;
}

void main() {
  // Google Play rejects bundles below API 24 when Play Auto Protect is on
  // (issue #U); the build file is the only place this is decided.
  test('the Android app targets at least API 24 for Play Auto Protect', () {
    expect(_sdkLevel('minSdk'), greaterThanOrEqualTo(24));
  });

  // Google Play rejects uploads whose target API level is below 36 (issue #V).
  test('the Android app targets API 36 as Google Play requires', () {
    final target = _sdkLevel('targetSdk');
    expect(target, greaterThanOrEqualTo(36));
    expect(_sdkLevel('compileSdk'), greaterThanOrEqualTo(target));
  });

  // Regression (GH-60): the receiving phone crashed the moment a direct
  // transfer started. libwebrtc's NetworkMonitor calls
  // ConnectivityManager.registerNetworkCallback without catching the
  // SecurityException it throws when this permission is missing, and the
  // native side turns any Java exception into abort().
  test('the Android app may watch the network, as WebRTC needs', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    expect(pubspec, contains('flutter_webrtc:'));
    final manifest =
        File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
    expect(
      manifest,
      contains(
        '<uses-permission android:name="android.permission.ACCESS_NETWORK_STATE"/>',
      ),
    );
  });

  // The Chinese name is the official one; other devices keep the English.
  test('the launcher shows 頁間 on Chinese devices', () {
    final manifest =
        File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
    expect(manifest, contains('android:label="@string/app_name"'));
    String appName(String values) => RegExp(
          r'<string name="app_name">([^<]*)</string>',
        )
            .firstMatch(
              File('android/app/src/main/res/$values/strings.xml')
                  .readAsStringSync(),
            )!
            .group(1)!;
    expect(appName('values-zh'), '頁間');
    expect(appName('values'), 'CoTime Book');
  });
}
