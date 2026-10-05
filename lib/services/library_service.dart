import 'dart:typed_data';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/app_constants.dart';
import '../models/library_book.dart';
import 'supabase_service.dart';

/// The public library: open-source books kept in a Storage bucket.
///
/// Injectable so the lobby and [BookNotifier] can be tested without Storage.
abstract interface class LibraryService {
  Future<List<LibraryBook>> listBooks();

  Future<Uint8List> download(String path);
}

class SupabaseLibraryService implements LibraryService {
  /// Far more than the library is expected to hold, and PostgREST's default
  /// cap; the browser loads the whole catalog and filters it on the device.
  static const listLimit = 1000;

  final String bucket;

  const SupabaseLibraryService({this.bucket = AppConstants.libraryBucket});

  StorageFileApi get _bucket => SupabaseService.client.storage.from(bucket);

  @override
  Future<List<LibraryBook>> listBooks() async {
    // The view lists the bucket (folders included) and joins the catalog
    // onto it, so a book without a catalog row is still listed.
    final rows = await SupabaseService.database
        .from('library_catalog')
        .select()
        .order('path')
        .limit(listLimit);
    return libraryBooksFromRows(rows);
  }

  @override
  Future<Uint8List> download(String path) => _bucket.download(path);
}

/// Keeps only what a reader can open, sorted by title.
List<LibraryBook> libraryBooksFromRows(List<Map<String, dynamic>> rows) {
  final books = <LibraryBook>[];
  for (final row in rows) {
    final book = LibraryBook.fromCatalogRow(row);
    // The bucket enforces the same limit; this covers a bucket whose limit
    // was raised by hand. Every device would refuse a larger book.
    final sizeBytes = book.sizeBytes;
    if (sizeBytes != null && sizeBytes > AppConstants.maxFileSize) continue;
    books.add(book);
  }
  books.sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
  return books;
}
