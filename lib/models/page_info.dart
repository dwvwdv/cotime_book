/// Where the page in view is, as the reader's page counter shows it.
///
/// Counted on the room's shared page, so every reader sees the same numbers:
/// the page's number in its chapter and the chapter's page count, both
/// without the blank pages a turn skips, and how far into the book it is.
class PageInfo {
  final int page;
  final int pages;

  /// 0.0 to 1.0; null until epub.js has worked out the book's locations,
  /// which it does in the background after the book opens.
  final double? progress;

  const PageInfo({required this.page, required this.pages, this.progress});

  /// From `cotimeSharedPage.pageInfo()`; null for anything else.
  static PageInfo? fromWire(Object? raw) {
    if (raw is! Map) return null;
    final page = raw['page'];
    final pages = raw['pages'];
    final percent = raw['percent'];
    if (page is! num || pages is! num || page < 1 || pages < page) return null;
    return PageInfo(
      page: page.toInt(),
      pages: pages.toInt(),
      progress: percent is num && percent.isFinite
          ? percent.toDouble().clamp(0.0, 1.0)
          : null,
    );
  }

  String get pageLabel => '$page / $pages';

  /// Whole percent, never 100 before the last page of the book is reached:
  /// "100%" on a page that still turns reads as a counter gone wrong.
  String? get progressLabel {
    final value = progress;
    if (value == null) return null;
    final percent = (value * 100).floor();
    return '${value >= 1 ? 100 : percent.clamp(0, 99)}%';
  }

  @override
  bool operator ==(Object other) =>
      other is PageInfo &&
      other.page == page &&
      other.pages == pages &&
      other.progress == progress;

  @override
  int get hashCode => Object.hash(page, pages, progress);
}
