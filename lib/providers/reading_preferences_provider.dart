import 'package:flutter/material.dart';
import 'package:flutter_epub_viewer/flutter_epub_viewer.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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
    this.fontSize = 18,
    this.volumeKeysTurnPages = false,
  });

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
    theme: EpubTheme.custom(
      backgroundDecoration: BoxDecoration(color: backgroundColor),
      foregroundColor: textColor,
    ),
  );

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

class ReadingPreferencesNotifier extends StateNotifier<ReadingPreferences> {
  ReadingPreferencesNotifier() : super(const ReadingPreferences());

  void setTheme(ReadingTheme theme) {
    state = state.copyWith(theme: theme);
  }

  void setFontSize(double size) {
    state = state.copyWith(
      fontSize: size.clamp(
        ReadingPreferences.minFontSize,
        ReadingPreferences.maxFontSize,
      ),
    );
  }

  void setVolumeKeysTurnPages(bool enabled) {
    state = state.copyWith(volumeKeysTurnPages: enabled);
  }
}

final readingPreferencesProvider =
    StateNotifierProvider<ReadingPreferencesNotifier, ReadingPreferences>(
  (ref) => ReadingPreferencesNotifier(),
);
