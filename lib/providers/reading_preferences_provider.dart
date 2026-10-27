import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_epub_viewer/flutter_epub_viewer.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/local_store.dart';
import 'local_store_provider.dart';

/// Preset reading themes for the EPUB reader.
enum ReadingTheme {
  day,
  night,
  sepia,
}

class ReadingPreferences {
  static const double minFontSize = 12;
  static const double maxFontSize = 32;
  static const double fontSizeStep = 2;
  static const double defaultFontSize = 18;

  final ReadingTheme theme;

  /// The smallest text this reader wants. The room reads at the largest size
  /// anyone picked, so every page holds the same text (issue #20).
  final double fontSize;

  /// Volume keys as page-turn keys. Off by default: on a phone they are the
  /// volume, and pressing one by habit would send a page-turn request to the
  /// whole room. E-readers whose page buttons emit volume codes opt in.
  final bool volumeKeysTurnPages;

  const ReadingPreferences({
    this.theme = ReadingTheme.day,
    this.fontSize = defaultFontSize,
    this.volumeKeysTurnPages = false,
  });

  /// What [store] remembers from earlier launches. Anything unusable falls
  /// back to its default on its own, so one bad value never costs the others.
  factory ReadingPreferences.restore(LocalStore store) {
    final size = store.readingFontSize;
    return ReadingPreferences(
      // A theme this version no longer has is not an error: start on Paper.
      theme:
          ReadingTheme.values.asNameMap()[store.readingTheme] ??
          ReadingTheme.day,
      // Clamped the same way the size buttons are, since the room reads at
      // the largest size anyone picked: an out-of-range size saved by some
      // other build would otherwise set the type for everyone (issue #20).
      fontSize: size != null && size.isFinite
          ? clampFontSize(size)
          : defaultFontSize,
      volumeKeysTurnPages: store.volumeKeysTurnPages ?? false,
    );
  }

  static double clampFontSize(double size) =>
      size.clamp(minFontSize, maxFontSize).toDouble();

  String get themeLabel {
    switch (theme) {
      case ReadingTheme.day:
        return 'Paper';
      case ReadingTheme.night:
        return 'Night';
      case ReadingTheme.sepia:
        return 'Sepia';
    }
  }

  // Paper and Night are pure ink and pure paper: anything in between is
  // dithered by an e-ink panel and reads as a gray haze over the text.
  Color get backgroundColor {
    switch (theme) {
      case ReadingTheme.day:
        return const Color(0xFFFFFFFF);
      case ReadingTheme.night:
        return const Color(0xFF000000);
      case ReadingTheme.sepia:
        return const Color(0xFFF5E6C8);
    }
  }

  Color get textColor {
    switch (theme) {
      case ReadingTheme.day:
        return const Color(0xFF000000);
      case ReadingTheme.night:
        return const Color(0xFFEDEDED);
      case ReadingTheme.sepia:
        return const Color(0xFF3A2A1C);
    }
  }

  /// What the EPUB viewer is loaded with.
  ///
  /// The theme has to be handed to the viewer itself. It used to be applied
  /// only to the Scaffold around it, so picking Night repainted the margins
  /// and left the page — the part being read — exactly as it was.
  ///
  /// [fontSize] is only where the viewer starts: the book is laid out on the
  /// room's shared page once it loads (issue #20).
  EpubDisplaySettings get displaySettings => EpubDisplaySettings(
    flow: EpubFlow.paginated,
    // One page, never a two-page spread: "auto" turns a wide screen into a
    // spread, which would hold twice the text of everyone else's page.
    spread: EpubSpread.none,
    snap: false,
    // flutter_epub_viewer 1.2.x otherwise installs its own Android
    // detectSwipe() handler even when snap is false, bypassing the consensus
    // overlay.
    useSnapAnimationAndroid: true,
    fontSize: fontSize.round(),
    theme: epubTheme,
  );

  EpubTheme get epubTheme => EpubTheme.custom(
    backgroundDecoration: BoxDecoration(color: backgroundColor),
    foregroundColor: textColor,
    customCss: themeRules,
  );

  /// Puts [themeRules] into the book once the viewer has loaded it.
  ///
  /// [displaySettings] alone is not enough: flutter_epub_viewer 1.2.x ends
  /// `loadBook()` by registering the theme once more without its custom CSS,
  /// which throws [themeRules] away before the first page is drawn. Call this
  /// when the chapters are loaded, which is after `loadBook()` has returned.
  Future<void> applyTheme(EpubController controller) async {
    await controller.updateTheme(theme: epubTheme);
  }

  /// The theme's colours over the book's own.
  ///
  /// The viewer paints [backgroundColor] behind a transparent WebView, and
  /// gives the book only a plain `body { color }`. Books colour themselves:
  /// Project Gutenberg's stylesheet has `body.tei.tei-text { color: black;
  /// background-color: white }`, which outranks that rule, so the page stayed
  /// white under Sepia and Night drew its light ink on the white page. Every
  /// box is cleared and every text takes the theme's ink, or a book's white
  /// box or black text would sink back into a Night page.
  ///
  /// Colours only: nothing here moves a line, so the shared page's breaks do
  /// not depend on the theme (issue #20).
  Map<String, dynamic> get themeRules => {
    'html, body, body *': {'background-color': 'transparent !important'},
    'body': {'color': '${_cssColor(textColor)} !important'},
    'body *': {'color': 'inherit !important'},
  };

  static String _cssColor(Color color) =>
      '#${(color.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';

  ReadingPreferences copyWith({
    ReadingTheme? theme,
    double? fontSize,
    bool? volumeKeysTurnPages,
  }) {
    return ReadingPreferences(
      theme: theme ?? this.theme,
      fontSize: fontSize ?? this.fontSize,
      volumeKeysTurnPages: volumeKeysTurnPages ?? this.volumeKeysTurnPages,
    );
  }
}

/// Remembered between launches (GH-32): e-reader users turn the type up,
/// and setting it again every time the app opened was the first thing they
/// did in every session.
///
/// The saved values are read synchronously when the notifier is built — the
/// preferences are loaded before the app starts — so the first state anyone
/// sees is already the remembered one. The reader's first page fit therefore
/// carries the remembered size, instead of publishing the default and then
/// correcting it with a second Presence update (issue #18).
class ReadingPreferencesNotifier extends StateNotifier<ReadingPreferences> {
  final LocalStore _store;

  ReadingPreferencesNotifier([LocalStore? store])
    : this._(store ?? LocalStore());

  ReadingPreferencesNotifier._(LocalStore store)
    : _store = store,
      super(ReadingPreferences.restore(store));

  void setTheme(ReadingTheme theme) {
    state = state.copyWith(theme: theme);
    unawaited(_store.saveReadingTheme(theme.name));
  }

  void setFontSize(double size) {
    if (!size.isFinite) return;
    final clamped = ReadingPreferences.clampFontSize(size);
    state = state.copyWith(fontSize: clamped);
    unawaited(_store.saveReadingFontSize(clamped));
  }

  void setVolumeKeysTurnPages(bool enabled) {
    state = state.copyWith(volumeKeysTurnPages: enabled);
    unawaited(_store.saveVolumeKeysTurnPages(enabled));
  }
}

final readingPreferencesProvider =
    StateNotifierProvider<ReadingPreferencesNotifier, ReadingPreferences>(
  (ref) => ReadingPreferencesNotifier(ref.read(localStoreProvider)),
);
