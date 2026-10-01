import 'package:cotime_book/app.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a passing interruption does not take the reader out of the room', () {
    // Regression (#F): `inactive` (notification shade, system dialog) was
    // treated like backgrounding, which dropped is_reading and cancelled the
    // page turn in progress.
    expect(appActivityFor(AppLifecycleState.inactive), isNull);
    expect(appActivityFor(AppLifecycleState.resumed), isTrue);
    expect(appActivityFor(AppLifecycleState.paused), isFalse);
    expect(appActivityFor(AppLifecycleState.hidden), isFalse);
    expect(appActivityFor(AppLifecycleState.detached), isFalse);
  });
}
