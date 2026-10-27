import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter_epub_viewer/flutter_epub_viewer.dart';

import '../models/page_info.dart';
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

  /// What is wrong with the layout on the page [apply] last put the book on:
  /// empty when every view is laid out on it, null when the viewer could not
  /// be asked (no page applied yet, the WebView gone).
  ///
  /// epub.js can leave a view laid out on a box other than the one it is
  /// shown in, which cuts the bottom lines off every page and makes turns
  /// skip text. It was only ever seen on a real Android WebView (GH-49), so
  /// the reader checks for it whenever the page settles rather than trusting
  /// [apply] alone.
  static Future<List<String>?> verify(EpubController controller) async {
    final webView = controller.webViewController;
    if (webView == null) return null;
    try {
      return layoutProblemsFrom(
        await webView.evaluateJavascript(
          source:
              'JSON.stringify(window.cotimeSharedPage ? '
              'window.cotimeSharedPage.verify() : null)',
        ),
      );
    } catch (_) {
      return null;
    }
  }

  /// Everything the viewer's script knows about what is on screen, for a
  /// reader to copy into a bug report. Null when it could not be asked.
  static Future<Map<String, dynamic>?> diagnose(
    EpubController controller,
  ) async {
    final webView = controller.webViewController;
    if (webView == null) return null;
    try {
      final decoded = _decode(
        await webView.evaluateJavascript(
          source:
              'JSON.stringify(window.cotimeSharedPage ? '
              'window.cotimeSharedPage.diagnose() : null)',
        ),
      );
      return decoded is Map ? Map<String, dynamic>.from(decoded) : null;
    } catch (_) {
      return null;
    }
  }

  /// Which page of its chapter is in view, and how far into the book. Null
  /// when the viewer could not be asked.
  static Future<PageInfo?> pageInfo(EpubController controller) async {
    final webView = controller.webViewController;
    if (webView == null) return null;
    try {
      return PageInfo.fromWire(
        _decode(
          await webView.evaluateJavascript(
            source:
                'JSON.stringify(window.cotimeSharedPage ? '
                'window.cotimeSharedPage.pageInfo() : null)',
          ),
        ),
      );
    } catch (_) {
      return null;
    }
  }

  /// The page start of the [page]th page (as the page counter numbers it)
  /// of the chapter in view. Null when there is no such page, or the viewer
  /// could not be asked.
  static Future<String?> pageStart(EpubController controller, int page) {
    return _ask<String>(controller, 'window.cotimeSharedPage.pageStart($page)');
  }

  /// Where [progress] (0 to 1) of the way into the book is. Null until the
  /// viewer has worked out the book's locations.
  static Future<String?> cfiAtProgress(
    EpubController controller,
    double progress,
  ) {
    return _ask<String>(
      controller,
      'window.cotimeSharedPage.cfiAtProgress(${progress.clamp(0.0, 1.0)})',
    );
  }

  /// How far into the book [cfi] is, 0 to 1. Null until the viewer has
  /// worked out the book's locations.
  static Future<double?> progressAt(
    EpubController controller,
    String cfi,
  ) async {
    final value = await _ask<num>(
      controller,
      'window.cotimeSharedPage.progressAt(${jsonEncode(cfi)})',
    );
    return value?.toDouble().clamp(0.0, 1.0);
  }

  /// Runs one of the script's queries; null when it is not installed (the
  /// book is not laid out on a shared page yet) or answered something else.
  static Future<T?> _ask<T>(EpubController controller, String call) async {
    final webView = controller.webViewController;
    if (webView == null) return null;
    try {
      // Wrapped: a bare string result comes back already decoded on some
      // platforms, and could not be told from JSON.
      final decoded = _decode(
        await webView.evaluateJavascript(
          source:
              'JSON.stringify({value: window.cotimeSharedPage ? $call : null})',
        ),
      );
      final value = decoded is Map ? decoded['value'] : null;
      return value is T ? value : null;
    } catch (_) {
      return null;
    }
  }

  /// [verify]'s result as the WebView hands it back: a JSON string on some
  /// platforms, already decoded on others.
  static List<String>? layoutProblemsFrom(Object? raw) {
    final decoded = _decode(raw);
    if (decoded is! List) return null;
    return [for (final problem in decoded) '$problem'];
  }

  static Object? _decode(Object? raw) {
    if (raw is! String) return raw;
    try {
      return jsonDecode(raw);
    } on FormatException {
      return null;
    }
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
