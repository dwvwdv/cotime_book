import 'dart:convert';
import 'dart:io';

import 'package:cotime_book/l10n/l10n.dart';
import 'package:cotime_book/providers/app_locale_provider.dart';
import 'package:cotime_book/services/local_store.dart';
import 'package:flutter/material.dart';
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

/// An app wired for languages the way CoTimeBookApp is.
Widget _app({Locale? locale, Widget home = const SizedBox()}) => MaterialApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: appLocales,
  locale: locale,
  builder: followAppLocale,
  home: home,
);

void main() {
  tearDown(() => useAppStringsOf(const Locale('en')));

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

    // A bare zh gave Material's Simplified built-ins (复制, 粘贴) in a
    // Traditional interface.
    testWidgets('gives Material its Traditional Chinese text too', (
      tester,
    ) async {
      tester.platformDispatcher.localesTestValue = const [Locale('zh', 'TW')];
      addTearDown(tester.platformDispatcher.clearLocalesTestValue);
      late BuildContext context;
      await tester.pumpWidget(
        _app(
          home: Builder(
            builder: (inner) {
              context = inner;
              return const SizedBox();
            },
          ),
        ),
      );

      expect(MaterialLocalizations.of(context).copyButtonLabel, '複製');
      expect(context.l10n.createRoom, '建立房間');
    });
  });

  // Provider state and service messages are made away from any widget; they
  // must come out in the language the screens are in.
  group('the strings made outside the widget tree', () {
    testWidgets('follow the language on screen', (tester) async {
      await tester.pumpWidget(_app(locale: appLocales.last));
      expect(appStrings.reconnectingToRoom, '正在重新連上房間...');
      await tester.pumpWidget(_app(locale: appLocales.first));
      expect(appStrings.reconnectingToRoom, 'Reconnecting to the room...');
    });

    // WidgetsApp resolves the device's languages again when they change,
    // even while MaterialApp.locale overrides them. appStrings used to be
    // set from that resolution, and turned Chinese under English screens.
    testWidgets('stay in the picked language when the device changes its', (
      tester,
    ) async {
      tester.platformDispatcher.localesTestValue = const [Locale('zh', 'TW')];
      addTearDown(tester.platformDispatcher.clearLocalesTestValue);
      await tester.pumpWidget(_app(locale: appLocales.first));
      expect(appStrings.createRoom, 'Create Room');

      tester.platformDispatcher.localesTestValue = const [
        Locale('zh', 'HK'),
        Locale('ja'),
      ];
      await tester.pump();
      expect(appStrings.createRoom, 'Create Room');
    });
  });

  group('the language picked on Home', () {
    test('follows the device until one is picked', () {
      expect(AppLocaleNotifier(LocalStore()).state, isNull);
    });

    // A language dropped from the app, or a hand-edited file, must not leave
    // a locale MaterialApp has no strings for.
    test('ignores a saved language the app does not have', () async {
      final store = LocalStore();
      await store.saveAppLanguage('fr');
      expect(AppLocaleNotifier(store).state, isNull);
    });

    test('toggles from the language on screen and saves it', () {
      final store = LocalStore();
      final notifier = AppLocaleNotifier(store);
      addTearDown(notifier.dispose);

      notifier.toggle(const Locale('en', 'US'));
      expect(notifier.state?.languageCode, 'zh');
      expect(store.appLanguage, 'zh');
      notifier.toggle(const Locale('zh'));
      expect(notifier.state?.languageCode, 'en');
      expect(store.appLanguage, 'en');
    });
  });
}
