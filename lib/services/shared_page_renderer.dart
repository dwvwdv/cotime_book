import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter_epub_viewer/flutter_epub_viewer.dart';

import '../models/shared_page.dart';
import 'shared_page_style.dart';

/// Puts a loaded viewer's book on the room's [SharedPage].
///
/// flutter_epub_viewer lays the book out on the whole WebView in the device's
/// fonts, and its own `customCss` never reaches the book (its `loadBook`
/// registers the theme a second time without it before the first section
/// renders). So the page box, text size and typography are applied from here,
/// through `assets/reader/shared_page.js`, once the book has loaded.
class SharedPageRenderer {
  SharedPageRenderer._();

  static const scriptAsset = 'assets/reader/shared_page.js';

  /// How long a WebView without async JavaScript gets to finish laying out.
  static const _fallbackSettle = Duration(milliseconds: 600);

  static Future<String>? _script;

  /// The most a page is enlarged: past this the text is larger than anyone
  /// in the room asked for by more than any screen difference explains.
  static const maxScale = 3.0;

  /// How much larger a viewer of [viewport] can draw [page] (GH-37): the
  /// page is the smallest screen's, so a tablet reading with a phone would
  /// otherwise show a phone-sized page in a wide margin. 1 when it does not
  /// grow. Rounded down, and kept a few pixels short of the edges, because
  /// the WebView rounds the scaled viewport to whole pixels and a page that
  /// overshoots it by one would lose its last line.
  static double scaleFor(SharedPage page, Size viewport) {
    final fit = math.min(
      (viewport.width - 4) / page.width,
      (viewport.height - 4) / page.height,
    );
    if (!fit.isFinite) return 1;
    final scale = (math.min(fit, maxScale) * 100).floorToDouble() / 100;
    return scale > 1 ? scale : 1;
  }

  /// Where [page] sits on a viewer of [viewport] unscaled: centred, never off
  /// the top-left edge.
  static Offset originFor(SharedPage page, Size viewport) {
    return Offset(
      math.max(0, ((viewport.width - page.width) / 2).floorToDouble()),
      math.max(0, ((viewport.height - page.height) / 2).floorToDouble()),
    );
  }

  /// Completes once the book has been laid out again; false when the viewer
  /// could not be reached.
  static Future<bool> apply(
    EpubController controller,
    SharedPage page,
    Size viewport,
  ) async {
    final webView = controller.webViewController;
    if (webView == null) return false;
    final script = await (_script ??= rootBundle
        .loadString(scriptAsset)
        .catchError((Object error) {
          _script = null;
          throw error;
        }));
    final rules = await SharedPageStyle.load();
    final origin = originFor(page, viewport);
    final arguments = <String, dynamic>{
      'page': {
        'width': page.width,
        'height': page.height,
        'fontSize': page.fontSize,
        'left': origin.dx,
        'top': origin.dy,
        'scale': scaleFor(page, viewport),
        'screenWidth': viewport.width,
        'rules': rules,
      },
    };

    await webView.evaluateJavascript(source: script);
    try {
      final result = await webView.callAsyncJavaScript(
        functionBody: 'return await window.cotimeSharedPage.apply(page);',
        arguments: arguments,
      );
      return result != null && result.error == null && result.value == true;
    } catch (_) {
      // iOS before 14 has no async JavaScript: fire it and give it a moment.
      await webView.evaluateJavascript(
        source:
            'window.cotimeSharedPage.apply(${jsonEncode(arguments['page'])});',
      );
      await Future<void>.delayed(_fallbackSettle);
      return true;
    }
  }
}
