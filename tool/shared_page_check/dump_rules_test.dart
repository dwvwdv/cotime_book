// Writes the stylesheets the app injects into the book, for check.js.
// Not part of `flutter test` (it only runs test/); check.js runs it.
import 'dart:convert';
import 'dart:io';

import 'package:cotime_book/providers/reading_preferences_provider.dart';
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

  test('dump reading theme rules', () {
    // What ReadingPreferences hands the viewer: the text colour loadBook()
    // takes, and the rules applyTheme() puts over the book's own colours.
    final themes = {
      for (final theme in ReadingTheme.values)
        theme.name: () {
          final prefs = ReadingPreferences(theme: theme);
          final ink = prefs.textColor.toARGB32() & 0xFFFFFF;
          return {
            'ink': '#${ink.toRadixString(16).padLeft(6, '0')}',
            'rules': prefs.themeRules,
          };
        }(),
    };
    File('build/shared_page_check/themes.json')
      ..createSync(recursive: true)
      ..writeAsStringSync(jsonEncode(themes));
  });
}
