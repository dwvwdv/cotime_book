// Writes the stylesheet the app injects into the book, for check.js.
// Not part of `flutter test` (it only runs test/); check.js runs it.
import 'dart:convert';
import 'dart:io';

import 'package:cotime_book/services/shared_page_style.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('dump shared page rules', () async {
    final rules = await SharedPageStyle.load(rootBundle);
    final out = File('build/shared_page_check/rules.json')
      ..createSync(recursive: true);
    out.writeAsStringSync(jsonEncode(rules));
  });
}
