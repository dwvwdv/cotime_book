import 'dart:convert';
import 'dart:io';

import 'package:cotime_book/l10n/l10n.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _arb(String name) =>
    jsonDecode(File('lib/l10n/$name').readAsStringSync())
        as Map<String, dynamic>;

/// The messages of an ARB file, without `@@locale` and the `@key` metadata.
Map<String, String> _messages(Map<String, dynamic> arb) => {
  for (final entry in arb.entries)
    if (!entry.key.startsWith('@')) entry.key: entry.value as String,
};

/// The placeholders a message shows: every `{name}`, inside a plural's
/// branches too. A plural's own variable only picks the wording, and a
/// language without plurals (Chinese) need not use it; the branch text
/// (`=1{is}`, `other{are}`) is not a placeholder.
Set<String> _placeholders(String message) => RegExp(
  r'(?<![=\w])\{(\w+)\}',
).allMatches(message).map((match) => match.group(1)!).toSet();

void main() {
  tearDown(() => resolveAppLocale(const [Locale('en', 'US')]));

  group('the Traditional Chinese strings', () {
    final english = _messages(_arb('app_en.arb'));
    final chinese = _messages(_arb('app_zh.arb'));

    // A key missing from app_zh.arb falls back to English without a word
    // from the build, so a new string would quietly stay English.
    test('translate every English string', () {
      expect(chinese.keys.toSet(), english.keys.toSet());
      for (final key in english.keys) {
        expect(chinese[key], isNotEmpty, reason: key);
      }
    });

    // A Chinese message that drops a name or count shows less than the
    // English one; one that names a placeholder the English lacks does not
    // build.
    test('use the same placeholders as the English', () {
      for (final key in english.keys) {
        expect(
          _placeholders(chinese[key]!),
          _placeholders(english[key]!),
          reason: key,
        );
      }
    });
  });

  group('the interface language', () {
    test('is Chinese on a Chinese device, whatever the region', () {
      for (final locale in const [
        Locale('zh', 'TW'),
        Locale('zh', 'HK'),
        Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant'),
        Locale('zh', 'CN'),
      ]) {
        expect(
          resolveAppLocale([locale]).languageCode,
          'zh',
          reason: '$locale',
        );
      }
    });

    test('is English on a device in any other language', () {
      expect(resolveAppLocale(const [Locale('ja', 'JP')]).languageCode, 'en');
      expect(resolveAppLocale(const [Locale('en', 'GB')]).languageCode, 'en');
      expect(resolveAppLocale(const []).languageCode, 'en');
    });

    test('takes the first of the device languages the app has', () {
      expect(
        resolveAppLocale(const [Locale('ja'), Locale('zh', 'TW')]).languageCode,
        'zh',
      );
    });

    // Provider state and service messages are made away from any widget; they
    // must come out in the language the screens resolved to.
    test('moves the strings made outside the widget tree with it', () {
      resolveAppLocale(const [Locale('zh', 'TW')]);
      expect(appStrings.reconnectingToRoom, '正在重新連上房間...');
      resolveAppLocale(const [Locale('en', 'US')]);
      expect(appStrings.reconnectingToRoom, 'Reconnecting to the room...');
    });
  });
}
