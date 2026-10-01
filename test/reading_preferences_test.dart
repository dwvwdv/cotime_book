import 'package:cotime_book/providers/reading_preferences_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_epub_viewer/flutter_epub_viewer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
}
