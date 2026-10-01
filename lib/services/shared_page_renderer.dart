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

  /// Where [page] sits on a viewer of [viewport]: centred, never off the
  /// top-left edge.
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
