import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../config/app_constants.dart';
import '../models/library_book.dart';
import 'supabase_service.dart';

/// The public library: open-source books kept in a public folder on the web.
///
/// Injectable so the lobby and [BookNotifier] can be tested without the
/// network.
abstract interface class LibraryService {
  Future<List<LibraryBook>> listBooks();

  Future<Uint8List> download(String path);

  /// Where a cover image in the library can be loaded from.
  String coverUrl(String path);

  /// The note about where the books come from, kept in the folder as
  /// [AppConstants.libraryNoticeFile] so the maintainers edit it along with
  /// the books.
  Future<String> readNotice();
}

/// Reads the files from a pCloud public folder ([AppConstants.libraryUrl])
/// and what they are from the catalog table in Supabase.
///
/// The books live outside Supabase so the library is not capped by the
/// project's Storage quota, and so a maintainer adds a book by dropping the
/// file into the folder. The catalog stays in the database, where it can be
/// edited as a table.
class PublicFolderLibraryService implements LibraryService {
  /// Far more than the library is expected to hold, and PostgREST's default
  /// cap; the browser loads the whole catalog and filters it on the device.
  static const listLimit = 1000;

  /// Long enough for a 40MB book on a slow connection. The room is asked for
  /// the book well before this (FileTransferService), so it only bounds how
  /// long a dead download holds its connection.
  static const downloadTimeout = Duration(minutes: 10);
  static const listTimeout = Duration(seconds: 30);

  final String baseUrl;
  final http.Client Function() _newClient;
  final Future<List<Map<String, dynamic>>> Function() _readCatalog;

  PublicFolderLibraryService({
    this.baseUrl = AppConstants.libraryUrl,
    http.Client Function()? client,
    Future<List<Map<String, dynamic>>> Function()? readCatalog,
  }) : _newClient = client ?? http.Client.new,
       _readCatalog = readCatalog ?? _readCatalogTable;

  static Future<List<Map<String, dynamic>>> _readCatalogTable() async {
    return SupabaseService.database
        .from('library_books')
        .select(
          'path, title, original_title, author, original_author, language, '
          'tags, cover_path',
        )
        .limit(listLimit);
  }

  @override
  Future<List<LibraryBook>> listBooks() async {
    // Both at once, and both awaited: a failed listing must not leave the
    // catalog's own failure unhandled.
    final (page, catalog) = await (
      _get(Uri.parse(baseUrl), listTimeout),
      _readCatalog(),
    ).wait;
    return libraryBooksFrom(parseLibraryListing(utf8.decode(page)), catalog);
  }

  @override
  Future<Uint8List> download(String path) =>
      _get(fileUri(path), downloadTimeout, maxBytes: AppConstants.maxFileSize);

  /// A note, not a book: anything larger is not the notice.
  static const noticeMaxBytes = 64 * 1024;

  @override
  Future<String> readNotice() async {
    final bytes = await _get(
      fileUri(AppConstants.libraryNoticeFile),
      listTimeout,
      maxBytes: noticeMaxBytes,
    );
    // Written by hand on any system: a Windows editor leaves a byte order
    // mark and CRLF line ends.
    return utf8
        .decode(bytes, allowMalformed: true)
        .replaceFirst('\uFEFF', '')
        .replaceAll('\r\n', '\n')
        .trim();
  }

  @override
  String coverUrl(String path) {
    final uri = Uri.tryParse(path);
    if (uri != null && uri.hasScheme) return path;
    return fileUri(path).toString();
  }

  /// [path] is a plain path inside the folder (isPlainLibraryPath); each
  /// segment is encoded on its own so a slash stays a folder.
  Uri fileUri(String path) {
    final base = baseUrl.endsWith('/') ? baseUrl : '$baseUrl/';
    return Uri.parse(base + path.split('/').map(Uri.encodeComponent).join('/'));
  }

  Future<Uint8List> _get(Uri uri, Duration timeout, {int? maxBytes}) async {
    final client = _newClient();
    try {
      final response = await client
          .send(http.Request('GET', uri))
          .timeout(timeout);
      if (response.statusCode != 200) {
        throw http.ClientException('HTTP ${response.statusCode}', uri);
      }
      final declared = response.contentLength;
      if (maxBytes != null && declared != null && declared > maxBytes) {
        throw http.ClientException('$declared bytes is too large', uri);
      }
      // Counted as it arrives: a file replaced in the folder after it was
      // listed could be any size, and every device refuses a larger book.
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in response.stream.timeout(timeout)) {
        bytes.add(chunk);
        if (maxBytes != null && bytes.length > maxBytes) {
          throw http.ClientException('The file is too large', uri);
        }
      }
      return bytes.takeBytes();
    } finally {
      client.close();
    }
  }
}

/// The EPUB files in a pCloud public folder's page.
///
/// The page is HTML, but it carries the listing as JSON in a script
/// (`var directLinkData = {...};`), which is what pCloud's own page renders
/// from. Folders (no size) and other files are left out, so covers can sit in
/// a subfolder and notes next to the books.
List<LibraryFile> parseLibraryListing(String html) {
  final match = RegExp(
    r'directLinkData\s*=\s*(\{.*?\})\s*;\s*</script>',
    dotAll: true,
  ).firstMatch(html);
  if (match == null) {
    throw const FormatException('The library page has no file listing');
  }
  final data = jsonDecode(match.group(1)!);
  final content = data is Map ? data['content'] : null;
  if (content is! List) {
    throw const FormatException('The library listing has no content');
  }
  final files = <LibraryFile>[];
  for (final entry in content) {
    if (entry is! Map) continue;
    final name = entry['name'];
    final size = entry['size'];
    if (name is! String || size is! num) continue;
    if (!name.toLowerCase().endsWith('.epub')) continue;
    files.add(LibraryFile(name, sizeBytes: size.toInt()));
  }
  return files;
}

/// The books in the folder, each with its catalog row if it has one, keeping
/// only what a reader can open, sorted by title. A row whose file is not in
/// the folder shows nothing.
List<LibraryBook> libraryBooksFrom(
  List<LibraryFile> files,
  List<Map<String, dynamic>> catalog,
) {
  final rows = {
    for (final row in catalog)
      if (row['path'] is String) row['path'] as String: row,
  };
  final books = <LibraryBook>[];
  for (final file in files) {
    // Every device would refuse a larger book, and the folder has no limit
    // of its own.
    final sizeBytes = file.sizeBytes;
    if (sizeBytes != null && sizeBytes > AppConstants.maxFileSize) continue;
    books.add(LibraryBook.fromCatalog(file, rows[file.path]));
  }
  books.sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
  return books;
}
