import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:cotime_book/models/library_book.dart';
import 'package:cotime_book/providers/book_provider.dart';
import 'package:cotime_book/providers/presence_provider.dart';
import 'package:cotime_book/providers/room_provider.dart';
import 'package:cotime_book/services/epub_storage_service.dart';
import 'package:cotime_book/services/library_service.dart';
import 'package:cotime_book/services/realtime_service.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'room_provider_test.dart' show FakeRoomService, testRoom;

class MemoryEpubStorage extends EpubStorageService {
  final Directory dir = Directory.systemTemp.createTempSync('books');
  final Map<String, Uint8List> saved = {};

  @override
  Future<File> saveBook(String hash, Uint8List bytes) async {
    saved[hash] = bytes;
    return File('${dir.path}/$hash.epub')..writeAsBytesSync(bytes);
  }

  @override
  Future<File?> getBookFile(String hash) async {
    final file = File('${dir.path}/$hash.epub');
    return file.existsSync() ? file : null;
  }
}

class SlowLibrary implements LibraryService {
  final downloads = <String, Completer<Uint8List>>{};

  @override
  Future<List<LibraryBook>> listBooks() async => const [];

  @override
  Future<Uint8List> download(String path) =>
      (downloads[path] = Completer<Uint8List>()).future;
}

/// Runs [onHoldingBook] while this device announces it holds a book: the
/// moment another member's share can arrive mid-announcement.
class HookedPresence extends PresenceNotifier {
  Future<void> Function(String bookHash)? onHoldingBook;

  HookedPresence() : super(RealtimeService());

  @override
  Future<void> updateHasBook(bool hasBook, {String? bookHash}) async {
    final hook = onHoldingBook;
    if (hasBook && bookHash != null && hook != null) {
      onHoldingBook = null;
      await hook(bookHash);
    }
    await super.updateHasBook(hasBook, bookHash: bookHash);
  }
}

void main() {
  test('a library download that finishes after someone else shared a book '
      'does not take the room back', () async {
    // Regression: the download only checked the room session, so a 40MB
    // book that took a minute replaced the book shared in the meantime.
    final storage = MemoryEpubStorage();
    addTearDown(() => storage.dir.deleteSync(recursive: true));
    final library = SlowLibrary();
    final container = ProviderContainer(
      overrides: [
        epubStorageProvider.overrideWithValue(storage),
        libraryServiceProvider.overrideWithValue(library),
      ],
    );
    addTearDown(container.dispose);
    final books = container.read(bookProvider.notifier);

    final aliceBook = Uint8List.fromList(List.generate(4000, (i) => i % 13));
    final sharing = books.shareLibraryBook(
      const LibraryBook(path: 'Alice.epub'),
    );
    expect(container.read(bookProvider).isLoading, isTrue);

    // Bob shares another book while Alice's download is still running.
    final bobHash = sha256.convert([1, 2, 3]).toString();
    await books.prepareForSharedBook(bobHash);

    library.downloads['Alice.epub']!.complete(aliceBook);
    await sharing;

    final state = container.read(bookProvider);
    expect(state.currentBook, isNull);
    expect(state.isLoading, isFalse);
    expect(state.error, isNull);
    expect(books.hasBook(sha256.convert(aliceBook).toString()), isFalse);
  });

  test('a library share that loses the race to another book follows it '
      'instead of announcing itself', () async {
    // Regression: after a revision conflict the share wrote over the book
    // committed first, then announced itself to the room.
    final otherBook = sha256.convert([9, 9, 9]).toString();
    final rooms = FakeRoomService()
      ..bookConflicts = 1
      ..conflictRoom = testRoom(
        revision: 7,
      ).copyWith(currentBookTitle: 'Bob', currentBookHash: otherBook);
    final storage = MemoryEpubStorage();
    addTearDown(() => storage.dir.deleteSync(recursive: true));
    final library = SlowLibrary();
    final container = ProviderContainer(
      overrides: [
        epubStorageProvider.overrideWithValue(storage),
        libraryServiceProvider.overrideWithValue(library),
        roomProvider.overrideWith((ref) => RoomNotifier(rooms)),
      ],
    );
    addTearDown(container.dispose);
    await container.read(roomProvider.notifier).createRoom('Alice');
    final books = container.read(bookProvider.notifier);

    final aliceBook = Uint8List.fromList(List.generate(4000, (i) => i % 13));
    final sharing = books.shareLibraryBook(
      const LibraryBook(path: 'Alice.epub'),
    );
    library.downloads['Alice.epub']!.complete(aliceBook);
    await sharing;

    final state = container.read(bookProvider);
    expect(rooms.bookExpectedRevisions, [0]);
    expect(state.currentBook, isNull);
    expect(state.isLoading, isFalse);
    // Announcing would have failed without a channel and left an error.
    expect(state.error, isNull);
    expect(books.hasBook(sha256.convert(aliceBook).toString()), isFalse);
    expect(
      container.read(roomProvider).currentRoom?.currentBookHash,
      otherBook,
    );
  });

  test('a share that arrives while this one is being announced wins', () async {
    // Regression: the Presence update was the last await before the
    // broadcast, and nothing checked for a newer share after it. Everyone who
    // had already moved to the newer book was pulled back.
    final storage = MemoryEpubStorage();
    addTearDown(() => storage.dir.deleteSync(recursive: true));
    final library = SlowLibrary();
    final presence = HookedPresence();
    final container = ProviderContainer(
      overrides: [
        epubStorageProvider.overrideWithValue(storage),
        libraryServiceProvider.overrideWithValue(library),
        roomProvider.overrideWith((ref) => RoomNotifier(FakeRoomService())),
        presenceProvider.overrideWith((ref) => presence),
      ],
    );
    addTearDown(container.dispose);
    await container.read(roomProvider.notifier).createRoom('Alice');
    final books = container.read(bookProvider.notifier);

    final bobHash = sha256.convert([7, 7, 7]).toString();
    presence.onHoldingBook = (_) => books.prepareForSharedBook(bobHash);
    final aliceBook = Uint8List.fromList(List.generate(4000, (i) => i % 13));
    final sharing = books.shareLibraryBook(
      const LibraryBook(path: 'Alice.epub'),
    );
    library.downloads['Alice.epub']!.complete(aliceBook);
    await sharing;

    final state = container.read(bookProvider);
    // Announcing would have failed without a channel and left an error.
    expect(state.error, isNull);
    expect(state.isLoading, isFalse);
    expect(books.hasBook(sha256.convert(aliceBook).toString()), isFalse);
  });

  test('a library download that fails after another book was shared does '
      'not report an error under that book', () async {
    // Regression: the failure of the abandoned download was written over the
    // state of the book that replaced it, and nothing cleared it.
    final storage = MemoryEpubStorage();
    addTearDown(() => storage.dir.deleteSync(recursive: true));
    final library = SlowLibrary();
    final container = ProviderContainer(
      overrides: [
        epubStorageProvider.overrideWithValue(storage),
        libraryServiceProvider.overrideWithValue(library),
      ],
    );
    addTearDown(container.dispose);
    final books = container.read(bookProvider.notifier);

    final sharing = books.shareLibraryBook(
      const LibraryBook(path: 'Alice.epub'),
    );
    await books.prepareForSharedBook(sha256.convert([1, 2, 3]).toString());
    library.downloads['Alice.epub']!.completeError(Exception('timed out'));
    await sharing;

    final state = container.read(bookProvider);
    expect(state.error, isNull);
    expect(state.isLoading, isFalse);
  });

  test('a library download that fails on its own is reported', () async {
    final storage = MemoryEpubStorage();
    addTearDown(() => storage.dir.deleteSync(recursive: true));
    final library = SlowLibrary();
    final container = ProviderContainer(
      overrides: [
        epubStorageProvider.overrideWithValue(storage),
        libraryServiceProvider.overrideWithValue(library),
      ],
    );
    addTearDown(container.dispose);
    final books = container.read(bookProvider.notifier);

    final sharing = books.shareLibraryBook(
      const LibraryBook(path: 'Alice.epub'),
    );
    library.downloads['Alice.epub']!.completeError(Exception('timed out'));
    await sharing;

    final state = container.read(bookProvider);
    expect(state.error, contains('Could not get "Alice" from the library'));
    expect(state.isLoading, isFalse);
  });
}
