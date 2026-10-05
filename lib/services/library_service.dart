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
  /// Far more than the library is expected to hold; Storage pages at 100 by
  /// default and the sheet has no paging.
  static const listLimit = 1000;

  final String bucket;

  const SupabaseLibraryService({this.bucket = AppConstants.libraryBucket});

  StorageFileApi get _bucket => SupabaseService.client.storage.from(bucket);

  @override
  Future<List<LibraryBook>> listBooks() async {
    final objects = await _bucket.list(
      searchOptions: const SearchOptions(
        limit: listLimit,
        sortBy: SortBy(column: 'name', order: 'asc'),
      ),
    );
    return libraryBooksFromObjects(objects);
  }

  @override
  Future<Uint8List> download(String path) => _bucket.download(path);
}

/// Keeps only what a reader can open: EPUB files the app will accept.
///
/// Folders come back from `list()` as entries without an id, and the
/// dashboard leaves `.emptyFolderPlaceholder` files behind.
List<LibraryBook> libraryBooksFromObjects(List<FileObject> objects) {
  final books = <LibraryBook>[];
  for (final object in objects) {
    if (object.id == null) continue;
    if (!object.name.toLowerCase().endsWith('.epub')) continue;
    final size = object.metadata?['size'];
    final sizeBytes = size is int ? size : null;
    // The bucket enforces the same limit; this covers a bucket whose limit
    // was raised by hand. Every device would refuse a larger book.
    if (sizeBytes != null && sizeBytes > AppConstants.maxFileSize) continue;
    books.add(LibraryBook(path: object.name, sizeBytes: sizeBytes));
  }
  books.sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
  return books;
}
