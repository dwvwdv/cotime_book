import 'package:cotime_book/providers/local_store_provider.dart';
import 'package:cotime_book/providers/reading_preferences_provider.dart';
import 'package:cotime_book/services/local_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_epub_viewer/flutter_epub_viewer.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The app as the next launch would start it: the same preferences on disk,
/// nothing carried over in memory.
Future<ProviderContainer> launch() async {
  final container = ProviderContainer(
    overrides: [
      localStoreProvider.overrideWithValue(
        LocalStore(await SharedPreferences.getInstance()),
      ),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('the chosen theme reaches the page, not just the margins', () {
    const night = ReadingPreferences(theme: ReadingTheme.night);
    final settings = night.displaySettings;

    expect(settings.theme, isNotNull);
    expect(settings.theme!.foregroundColor, night.textColor);
    expect(
      (settings.theme!.backgroundDecoration as BoxDecoration).color,
      night.backgroundColor,
    );
    // Night must actually be dark ink-on-black, not a gray that an e-ink
    // panel dithers into haze.
    expect(night.backgroundColor, const Color(0xFF000000));
  });

  test('the type size reaches the viewer', () {
    const prefs = ReadingPreferences(fontSize: 24);
    expect(prefs.displaySettings.fontSize, 24);
  });

  test('the viewer never gets its own swipe handler', () {
    // flutter_epub_viewer installs an Android swipe handler unless the snap
    // animation flag is set. That handler turns pages locally, skipping the
    // consensus protocol entirely.
    final settings = const ReadingPreferences().displaySettings;
    expect(settings.snap, isFalse);
    expect(settings.useSnapAnimationAndroid, isTrue);
    expect(settings.flow, EpubFlow.paginated);
  });

  test('a wide screen shows one page, not a two-page spread', () {
    // A tablet in landscape would otherwise hold twice the text of a phone's
    // page, and the room's pages would drift apart (issue #20).
    expect(const ReadingPreferences().displaySettings.spread, EpubSpread.none);
  });

  test('type size stays within a readable range', () {
    final notifier = ReadingPreferencesNotifier();
    notifier.setFontSize(4);
    expect(notifier.state.fontSize, ReadingPreferences.minFontSize);
    notifier.setFontSize(400);
    expect(notifier.state.fontSize, ReadingPreferences.maxFontSize);
  });

  test('volume keys are left alone unless the reader opts in', () {
    final notifier = ReadingPreferencesNotifier();
    expect(notifier.state.volumeKeysTurnPages, isFalse);
    notifier.setVolumeKeysTurnPages(true);
    expect(notifier.state.volumeKeysTurnPages, isTrue);
    // Changing the theme must not reset it.
    notifier.setTheme(ReadingTheme.night);
    expect(notifier.state.volumeKeysTurnPages, isTrue);
  });

  group('across launches', () {
    test('theme, type size and volume keys are remembered', () async {
      final first = await launch();
      first.read(readingPreferencesProvider.notifier)
        ..setTheme(ReadingTheme.night)
        ..setFontSize(26)
        ..setVolumeKeysTurnPages(true);
      await pumpEventQueue();

      final prefs = (await launch()).read(readingPreferencesProvider);
      expect(prefs.theme, ReadingTheme.night);
      expect(prefs.fontSize, 26);
      expect(prefs.volumeKeysTurnPages, isTrue);
    });

    test('a first launch starts on the defaults', () async {
      final prefs = (await launch()).read(readingPreferencesProvider);
      expect(prefs.theme, ReadingTheme.day);
      expect(prefs.fontSize, ReadingPreferences.defaultFontSize);
      expect(prefs.volumeKeysTurnPages, isFalse);
    });

    test('the reader opens on the remembered size, not the default first',
        () async {
      // The type size is published in Presence as part of the page fit, and
      // Presence updates are rate limited (issue #18): starting on the default
      // and then switching would cost the room a second update for nothing.
      SharedPreferences.setMockInitialValues({'reading_font_size': 24.0});
      final container = await launch();
      final seen = <double>[];
      container.listen<ReadingPreferences>(
        readingPreferencesProvider,
        (_, next) => seen.add(next.fontSize),
        fireImmediately: true,
      );
      await pumpEventQueue();

      expect(seen, [24]);
    });

    test('values this version cannot use fall back to their defaults',
        () async {
      SharedPreferences.setMockInitialValues({
        'reading_theme': 'neon',
        'reading_font_size': 'large',
        'volume_keys_turn_pages': 'yes',
      });
      final prefs = (await launch()).read(readingPreferencesProvider);
      expect(prefs.theme, ReadingTheme.day);
      expect(prefs.fontSize, ReadingPreferences.defaultFontSize);
      expect(prefs.volumeKeysTurnPages, isFalse);
    });

    test('a saved size out of range is brought back into it', () async {
      // The room reads at the largest size anyone picked, so a size no button
      // could produce would set the type for everyone.
      SharedPreferences.setMockInitialValues({'reading_font_size': 400.0});
      expect(
        (await launch()).read(readingPreferencesProvider).fontSize,
        ReadingPreferences.maxFontSize,
      );

      SharedPreferences.setMockInitialValues({'reading_font_size': 3});
      expect(
        (await launch()).read(readingPreferencesProvider).fontSize,
        ReadingPreferences.minFontSize,
      );

      SharedPreferences.setMockInitialValues({
        'reading_font_size': double.nan,
      });
      expect(
        (await launch()).read(readingPreferencesProvider).fontSize,
        ReadingPreferences.defaultFontSize,
      );
    });

    test('one unusable value does not cost the others', () async {
      SharedPreferences.setMockInitialValues({
        'reading_theme': 'sepia',
        'reading_font_size': 'large',
        'volume_keys_turn_pages': true,
      });
      final prefs = (await launch()).read(readingPreferencesProvider);
      expect(prefs.theme, ReadingTheme.sepia);
      expect(prefs.fontSize, ReadingPreferences.defaultFontSize);
      expect(prefs.volumeKeysTurnPages, isTrue);
    });

    test('without preferences the choice still lasts the session', () {
      final store = LocalStore();
      ReadingPreferencesNotifier(store).setFontSize(28);
      expect(ReadingPreferencesNotifier(store).state.fontSize, 28);
    });
  });
}
