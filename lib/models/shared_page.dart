import 'dart:math' as math;
import 'dart:ui' show Size;

/// How much room one reader has for the page, and the text size they asked
/// for. Published in Presence while the reader is open.
///
/// epub.js paginates by the box and the fonts it is given. Readers on
/// different screens used to lay the book out on their own screens, so "the
/// same page" held different text on each, and every turn moved each reader by
/// their own page length until they were on different parts of the book
/// (issue #20). Each reader now says what fits it, and everyone lays the book
/// out on the one [SharedPage] that fits all of them.
class PageFit {
  /// Smaller than this and a malformed or half-measured fit would squeeze the
  /// page down for the whole room.
  static const int minWidth = 240;
  static const int minHeight = 320;
  static const int minFontSize = 8;
  static const int maxFontSize = 72;

  /// Logical pixels, which are CSS pixels inside the WebView.
  final int width;
  final int height;
  final int fontSize;

  const PageFit({
    required this.width,
    required this.height,
    required this.fontSize,
  });

  /// [size] is the area the viewer has on this screen.
  factory PageFit.of(Size size, {required double fontSize}) {
    return PageFit(
      width: math.max(minWidth, size.width.floor()),
      height: math.max(minHeight, size.height.floor()),
      fontSize: fontSize.round().clamp(minFontSize, maxFontSize),
    );
  }

  Map<String, dynamic> toWire() => {'w': width, 'h': height, 'font': fontSize};

  /// Null for anything that is not a usable fit, so a peer on another version
  /// or a truncated payload is left out instead of shrinking the page.
  static PageFit? fromWire(Object? raw) {
    if (raw is! Map) return null;
    final width = raw['w'];
    final height = raw['h'];
    final fontSize = raw['font'];
    if (width is! num || height is! num || fontSize is! num) return null;
    if (!width.isFinite || !height.isFinite || !fontSize.isFinite) return null;
    return PageFit(
      width: math.max(minWidth, width.floor()),
      height: math.max(minHeight, height.floor()),
      fontSize: fontSize.round().clamp(minFontSize, maxFontSize),
    );
  }

  /// What one person needs when they read on several devices at once: every
  /// device has to show the same page, so it must fit all of them.
  static PageFit? combine(Iterable<PageFit> fits) {
    PageFit? combined;
    for (final fit in fits) {
      combined = combined == null
          ? fit
          : PageFit(
              width: math.min(combined.width, fit.width),
              height: math.min(combined.height, fit.height),
              fontSize: math.max(combined.fontSize, fit.fontSize),
            );
    }
    return combined;
  }

  @override
  bool operator ==(Object other) =>
      other is PageFit &&
      other.width == width &&
      other.height == height &&
      other.fontSize == fontSize;

  @override
  int get hashCode => Object.hash(width, height, fontSize);

  @override
  String toString() => 'PageFit(${width}x$height, ${fontSize}px)';
}

/// The page every reader in the room lays the book out on: the same box and
/// the same text size everywhere, so a page holds the same text on every
/// screen. It is as small as the smallest screen and its text as large as
/// the largest size anyone asked for; a bigger screen shows it with wider
/// margins.
class SharedPage {
  final int width;
  final int height;
  final int fontSize;

  const SharedPage({
    required this.width,
    required this.height,
    required this.fontSize,
  });

  factory SharedPage.fromFit(PageFit fit) =>
      SharedPage(width: fit.width, height: fit.height, fontSize: fit.fontSize);

  /// The page for this reader ([own]) and every other reader in the book.
  ///
  /// [onlineUsers] are merged Presence rows (one per user, see
  /// `mergePresenceUsers`). Only people in the reader count: someone in the
  /// lobby is not looking at a page, and their fit is not published anyway.
  /// The caller decides whether Presence is current enough to use.
  static SharedPage forRoom({
    required PageFit own,
    required List<Map<String, dynamic>> onlineUsers,
  }) {
    final fits = <PageFit>[own];
    for (final user in onlineUsers) {
      if (user['is_reading'] != true) continue;
      final fit = PageFit.fromWire(user['page_fit']);
      if (fit != null) fits.add(fit);
    }
    return SharedPage.fromFit(PageFit.combine(fits)!);
  }

  /// [forRoom] when Presence is current; otherwise the page this reader was
  /// already on, only ever made to fit [own] better. Presence that is stale or
  /// empty (reconnecting) says nothing about who left, so the page must not
  /// grow on it — but this reader's own screen and text size are always known.
  static SharedPage resolve({
    required PageFit own,
    required List<Map<String, dynamic>> onlineUsers,
    required bool presenceIsCurrent,
    SharedPage? previous,
  }) {
    if (presenceIsCurrent) {
      return forRoom(own: own, onlineUsers: onlineUsers);
    }
    if (previous == null) return SharedPage.fromFit(own);
    return SharedPage.fromFit(PageFit.combine([previous._asFit, own])!);
  }

  PageFit get _asFit =>
      PageFit(width: width, height: height, fontSize: fontSize);

  @override
  bool operator ==(Object other) =>
      other is SharedPage &&
      other.width == width &&
      other.height == height &&
      other.fontSize == fontSize;

  @override
  int get hashCode => Object.hash(width, height, fontSize);

  @override
  String toString() => 'SharedPage(${width}x$height, ${fontSize}px)';
}
