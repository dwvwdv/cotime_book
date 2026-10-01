import 'dart:convert';

import 'package:flutter/services.dart';

/// The typography every reader's copy of the book is laid out with.
///
/// A shared page box is not enough on its own (issue #20): with the book's
/// text in each device's system font (Roboto here, MiSans or an e-reader's own
/// font there), the same box still breaks lines in different places, and the
/// pages drift apart within a few turns. So the book is set in a bundled font
/// and everything that depends on a device's fonts, dictionaries or WebView
/// version is pinned.
class SharedPageStyle {
  SharedPageStyle._();

  /// The family name the book is set in. Not the font's real name, so a copy
  /// of Literata installed on the device can never stand in for the bundled
  /// files.
  static const fontFamily = 'CoTime Page';

  static const fontDirectory = 'assets/fonts/literata';

  /// Fixed rather than the book's: `normal` takes its height from the
  /// font that happens to draw each line, and CJK text is drawn by whatever
  /// CJK font the device has.
  static const lineHeight = '1.6';

  /// From the font's own subsetting. Text outside these ranges (CJK above
  /// all) falls back to the device's serif font; CJK glyphs are one em wide
  /// in every CJK font, and the line height is pinned, so the fallback does
  /// not move line breaks.
  static const subsets = <String, String>{
    'latin':
        'U+0000-00FF,U+0131,U+0152-0153,U+02BB-02BC,U+02C6,U+02DA,U+02DC,'
        'U+0304,U+0308,U+0329,U+2000-206F,U+20AC,U+2122,U+2191,U+2193,'
        'U+2212,U+2215,U+FEFF,U+FFFD',
    'latin-ext':
        'U+0100-02BA,U+02BD-02C5,U+02C7-02CC,U+02CE-02D7,U+02DD-02FF,U+0304,'
        'U+0308,U+0329,U+1D00-1DBF,U+1E00-1E9F,U+1EF2-1EFF,U+2020,'
        'U+20A0-20AB,U+20AD-20C0,U+2113,U+2C60-2C7F,U+A720-A7FF',
    'cyrillic': 'U+0301,U+0400-045F,U+0490-0491,U+04B0-04B1,U+2116',
    'greek':
        'U+0370-0377,U+037A-037F,U+0384-038A,U+038C,U+038E-03A1,U+03A3-03FF',
  };

  static const weights = [400, 700];
  static const styles = ['normal', 'italic'];

  static String fontAsset(String subset, int weight, String style) =>
      '$fontDirectory/literata-$subset-$weight-$style.woff2';

  static Future<Map<String, dynamic>>? _cached;

  /// The epub.js theme rules, built once per app run.
  static Future<Map<String, dynamic>> load([AssetBundle? bundle]) {
    if (bundle != null) return _build(bundle);
    return _cached ??= _build(rootBundle).catchError((Object error) {
      _cached = null;
      throw error;
    });
  }

  static Future<Map<String, dynamic>> _build(AssetBundle bundle) async {
    final files = <String, Uint8List>{};
    for (final subset in subsets.keys) {
      for (final weight in weights) {
        for (final style in styles) {
          final asset = fontAsset(subset, weight, style);
          final data = await bundle.load(asset);
          files[asset] = data.buffer.asUint8List(
            data.offsetInBytes,
            data.lengthInBytes,
          );
        }
      }
    }
    return rules(files);
  }

  /// Rules in the object form epub.js's `themes.default()` takes. [files]
  /// maps [fontAsset] paths to their bytes.
  static Map<String, dynamic> rules(Map<String, Uint8List> files) {
    final faces = <Map<String, dynamic>>[];
    for (final subset in subsets.entries) {
      for (final weight in weights) {
        for (final style in styles) {
          final bytes = files[fontAsset(subset.key, weight, style)];
          if (bytes == null) continue;
          faces.add({
            'font-family': '"$fontFamily"',
            'font-style': style,
            'font-weight': '$weight',
            // Inline: the book's sections are not served from the app's
            // origin, so a file URL would be refused.
            'src':
                'url(data:font/woff2;base64,${base64Encode(bytes)}) '
                'format("woff2")',
            'unicode-range': subset.value,
            'font-display': 'block',
          });
        }
      }
    }

    return {
      '@font-face': faces,
      'html': {
        // Android's font boosting would enlarge text by its own heuristics.
        '-webkit-text-size-adjust': '100% !important',
        'text-size-adjust': '100% !important',
      },
      'body, body *': {
        'font-family': '"$fontFamily", serif !important',
        'line-height': '$lineHeight !important',
        // Hyphenation dictionaries differ per device; soft hyphens in the
        // book still work.
        '-webkit-hyphens': 'manual !important',
        'hyphens': 'manual !important',
        // Newer WebViews tighten CJK punctuation and space CJK from Latin
        // using the font's own metrics; older ones do neither.
        'text-spacing-trim': 'space-all !important',
        'text-autospace': 'no-autospace !important',
      },
    };
  }
}
