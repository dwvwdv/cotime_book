/// A book in the public library: one EPUB file in the library bucket, plus
/// what the catalog says about it.
///
/// The catalog is optional per book: a file the maintainers have not described
/// yet still shows, titled by its file name and without author, language or
/// category.
class LibraryBook {
  /// The object's path in the bucket, which is also how it is downloaded.
  final String path;
  final int? sizeBytes;
  final String? _catalogTitle;
  final String? author;

  /// A BCP 47 tag such as `en` or `zh-Hant`; see [languageName].
  final String? language;
  final String? category;

  /// An image object in the library bucket, shown as the book's cover.
  final String? coverPath;

  const LibraryBook({
    required this.path,
    this.sizeBytes,
    String? title,
    this.author,
    this.language,
    this.category,
    this.coverPath,
  }) : _catalogTitle = title;

  /// A row of `cotime_book.library_catalog`. Blank catalog fields read as
  /// missing, so a half-filled row in the dashboard does not show empty
  /// labels or an empty filter.
  factory LibraryBook.fromCatalogRow(Map<String, dynamic> row) {
    final size = row['size_bytes'];
    return LibraryBook(
      path: row['path'] as String,
      sizeBytes: size is num ? size.toInt() : null,
      title: _text(row['title']),
      author: _text(row['author']),
      language: _text(row['language']),
      category: _text(row['category']),
      coverPath: _text(row['cover_path']),
    );
  }

  static String? _text(Object? value) {
    if (value is! String) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  String get fileName => path.split('/').last;

  /// The catalog's title, or else the file name. Storage keys are often
  /// written with underscores for spaces, so those read as spaces.
  String get title {
    final catalogTitle = _catalogTitle;
    if (catalogTitle != null) return catalogTitle;
    final name = fileName;
    final withoutExtension = name.toLowerCase().endsWith('.epub')
        ? name.substring(0, name.length - '.epub'.length)
        : name;
    final title = withoutExtension.replaceAll('_', ' ').trim();
    return title.isEmpty ? name : title;
  }

  /// The language as a reader would name it, or null when uncatalogued.
  String? get languageName {
    final tag = language;
    return tag == null ? null : describeLanguage(tag);
  }

  String? get sizeFormatted {
    final bytes = sizeBytes;
    if (bytes == null) return null;
    if (bytes < 1024 * 1024) return '${(bytes / 1024).ceil()} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  @override
  bool operator ==(Object other) =>
      other is LibraryBook &&
      other.path == path &&
      other.sizeBytes == sizeBytes &&
      other._catalogTitle == _catalogTitle &&
      other.author == author &&
      other.language == language &&
      other.category == category &&
      other.coverPath == coverPath;

  @override
  int get hashCode => Object.hash(
    path,
    sizeBytes,
    _catalogTitle,
    author,
    language,
    category,
    coverPath,
  );
}

/// Names a BCP 47 tag. The catalog is filled in by hand, so the same language
/// may arrive as `zh-TW` in one row and `zh-Hant` in another; both read as one
/// name and therefore filter as one language. Unknown tags show as written.
String describeLanguage(String tag) {
  final parts = tag.trim().replaceAll('_', '-').toLowerCase().split('-');
  final primary = parts.first;
  if (primary == 'zh') {
    if (parts.any((part) => const {'hant', 'tw', 'hk', 'mo'}.contains(part))) {
      return 'Chinese (Traditional)';
    }
    if (parts.any((part) => const {'hans', 'cn', 'sg'}.contains(part))) {
      return 'Chinese (Simplified)';
    }
    return 'Chinese';
  }
  return _languageNames[primary] ?? tag.trim();
}

const _languageNames = {
  'en': 'English',
  'ja': 'Japanese',
  'ko': 'Korean',
  'fr': 'French',
  'de': 'German',
  'es': 'Spanish',
  'it': 'Italian',
  'pt': 'Portuguese',
  'ru': 'Russian',
  'la': 'Latin',
  'el': 'Greek',
  'nl': 'Dutch',
  'vi': 'Vietnamese',
  'th': 'Thai',
};

/// What the library browser is narrowed to. Null filters mean "all".
class LibraryFilter {
  final String query;
  final String? category;

  /// Compared with [LibraryBook.languageName], not the raw tag.
  final String? language;

  const LibraryFilter({this.query = '', this.category, this.language});

  bool get isEmpty =>
      query.trim().isEmpty && category == null && language == null;

  /// Every word of the query has to appear in the title, the author or the
  /// file name, in any order. Chinese has no spaces between words, so a
  /// Chinese query is matched as one piece.
  bool matches(LibraryBook book) {
    if (category != null && book.category != category) return false;
    if (language != null && book.languageName != language) return false;
    final words = query.toLowerCase().split(RegExp(r'\s+'))
      ..removeWhere((word) => word.isEmpty);
    if (words.isEmpty) return true;
    final haystack = [
      book.title,
      book.author ?? '',
      book.fileName,
    ].join('\n').toLowerCase();
    return words.every(haystack.contains);
  }

  List<LibraryBook> apply(List<LibraryBook> books) =>
      isEmpty ? books : books.where(matches).toList();
}

/// The categories the books are filed under, for the filter row.
List<String> libraryCategories(List<LibraryBook> books) =>
    _distinctSorted(books.map((book) => book.category));

/// The languages the books are in, by name, for the filter row.
List<String> libraryLanguages(List<LibraryBook> books) =>
    _distinctSorted(books.map((book) => book.languageName));

List<String> _distinctSorted(Iterable<String?> values) {
  final distinct = values.whereType<String>().toSet().toList()
    ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  return distinct;
}
