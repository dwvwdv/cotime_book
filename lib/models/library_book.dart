import 'package:collection/collection.dart';

/// A book in the public library: one EPUB file in the library folder, plus
/// what the catalog says about it.
///
/// The catalog is optional per book: a file the maintainers have not described
/// yet still shows, titled by its file name and without author, language or
/// tags.
class LibraryBook {
  /// The file's path in the library folder, which is also how it is
  /// downloaded and how the catalog and the room refer to it.
  final String path;
  final int? sizeBytes;
  final String? _catalogTitle;

  /// The title the book was published under, when [title] is a translation
  /// of it (a Chinese title for an English book). Searchable, not shown.
  final String? originalTitle;
  final String? author;

  /// The author's name as it is written in the book, when [author] is a
  /// translation of it.
  final String? originalAuthor;

  /// A BCP 47 tag such as `en` or `zh-Hant`: the language the book is
  /// written in, not the language of its catalog entry. See [languageName].
  final String? language;

  /// What the book can be found under in the browser's filter. A book can
  /// carry any number of them.
  final List<String> tags;

  /// An image in the library folder (or a full URL), shown as the cover.
  final String? coverPath;

  const LibraryBook({
    required this.path,
    this.sizeBytes,
    String? title,
    this.originalTitle,
    this.author,
    this.originalAuthor,
    this.language,
    this.tags = const [],
    this.coverPath,
  }) : _catalogTitle = title;

  /// [file] as described by its row of `cotime_book.library_books`, if it has
  /// one. Blank catalog fields read as missing, so a half-filled row in the
  /// dashboard does not show empty labels or an empty filter.
  factory LibraryBook.fromCatalog(LibraryFile file, Map<String, dynamic>? row) {
    final tags = <String>[];
    final rawTags = row?['tags'];
    if (rawTags is List) {
      for (final tag in rawTags) {
        final text = _text(tag);
        if (text != null && !tags.contains(text)) tags.add(text);
      }
    }
    return LibraryBook(
      path: file.path,
      sizeBytes: file.sizeBytes,
      title: _text(row?['title']),
      originalTitle: _text(row?['original_title']),
      author: _text(row?['author']),
      originalAuthor: _text(row?['original_author']),
      language: _text(row?['language']),
      tags: List.unmodifiable(tags),
      coverPath: _text(row?['cover_path']),
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

  /// The language as the ribbon on the cover names it ("English",
  /// "Chinese"), or null when uncatalogued. Only the primary subtag: the
  /// ribbon is a glance, and the filter tells Traditional and Simplified
  /// Chinese apart.
  String? get languageBadge {
    final primary = language?.trim().replaceAll('_', '-').split('-').first;
    if (primary == null || primary.isEmpty) return null;
    return describeLanguage(primary);
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
      other.originalTitle == originalTitle &&
      other.author == author &&
      other.originalAuthor == originalAuthor &&
      other.language == language &&
      const ListEquality<String>().equals(other.tags, tags) &&
      other.coverPath == coverPath;

  @override
  int get hashCode => Object.hash(
    path,
    sizeBytes,
    _catalogTitle,
    originalTitle,
    author,
    originalAuthor,
    language,
    Object.hashAll(tags),
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

/// What the library browser is narrowed to. No tags and a null language
/// mean "all".
class LibraryFilter {
  final String query;

  /// A book has to carry at least one of these: picking another tag adds
  /// its books to the shelf.
  final Set<String> tags;

  /// Compared with [LibraryBook.languageName], not the raw tag.
  final String? language;

  const LibraryFilter({this.query = '', this.tags = const {}, this.language});

  bool get isEmpty => query.trim().isEmpty && tags.isEmpty && language == null;

  /// Every word of the query has to appear in the title, the author (either
  /// as catalogued or as in the original) or the file name, in any order.
  /// Chinese has no spaces between words, so a Chinese query is matched as
  /// one piece.
  bool matches(LibraryBook book) {
    if (tags.isNotEmpty && !tags.any(book.tags.contains)) return false;
    if (language != null && book.languageName != language) return false;
    final words = query.toLowerCase().split(RegExp(r'\s+'))
      ..removeWhere((word) => word.isEmpty);
    if (words.isEmpty) return true;
    final haystack = [
      book.title,
      book.originalTitle ?? '',
      book.author ?? '',
      book.originalAuthor ?? '',
      book.fileName,
    ].join('\n').toLowerCase();
    return words.every(haystack.contains);
  }

  List<LibraryBook> apply(List<LibraryBook> books) =>
      isEmpty ? books : books.where(matches).toList();
}

/// The tags the books carry, for the filter row: the most used first, so the
/// broad shelves lead and a tag only one book has comes last.
List<String> libraryTags(List<LibraryBook> books) {
  final counts = <String, int>{};
  for (final book in books) {
    for (final tag in book.tags) {
      counts[tag] = (counts[tag] ?? 0) + 1;
    }
  }
  return counts.keys.toList()..sort((a, b) {
    final byCount = counts[b]!.compareTo(counts[a]!);
    return byCount != 0 ? byCount : a.compareTo(b);
  });
}

/// The languages the books are in, by name, for the filter row.
List<String> libraryLanguages(List<LibraryBook> books) {
  final distinct =
      books
          .map((book) => book.languageName)
          .whereType<String>()
          .toSet()
          .toList()
        ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  return distinct;
}

/// A file in the library folder, before the catalog has said anything about
/// it.
class LibraryFile {
  final String path;
  final int? sizeBytes;

  const LibraryFile(this.path, {this.sizeBytes});
}
