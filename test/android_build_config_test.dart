import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  // Google Play rejects bundles below API 24 when Play Auto Protect is on
  // (issue #U); the build file is the only place this is decided.
  test('the Android app targets at least API 24 for Play Auto Protect', () {
    final gradle = File('android/app/build.gradle').readAsStringSync();
    final match = RegExp(r'^\s*minSdk\s*=\s*(\S+)', multiLine: true)
        .firstMatch(gradle);

    expect(match, isNotNull, reason: 'minSdk must be set in build.gradle');
    final minSdk = int.tryParse(match!.group(1)!);
    expect(minSdk, isNotNull,
        reason: 'minSdk must be a literal, not flutter.minSdkVersion (21)');
    expect(minSdk, greaterThanOrEqualTo(24));
  });
}
