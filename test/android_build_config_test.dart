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
}
