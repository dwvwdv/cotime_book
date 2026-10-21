import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:cotime_book/config/app_constants.dart';
import 'package:cotime_book/models/library_book.dart';
import 'package:cotime_book/providers/book_provider.dart';
import 'package:cotime_book/providers/presence_provider.dart';
import 'package:cotime_book/providers/room_provider.dart';
import 'package:cotime_book/services/epub_storage_service.dart';
import 'package:cotime_book/services/library_service.dart';
import 'package:cotime_book/services/realtime_service.dart';
import 'package:cotime_book/services/txt_book.dart';
import 'package:archive/archive.dart';
import 'dart:convert';
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

  @override
  String coverUrl(String path) => 'https://library.test/$path';
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

/// A channel that is always connected and keeps what was broadcast.
class RecordingRealtime extends RealtimeService {
  final events = <String>[];

  @override
  Future<void> broadcast({
    required String event,
    required Map<String, dynamic> payload,
  }) async {
    events.add(event);
  }
}

TxtSource txt(String name, String text) =>
    TxtSource(fileName: name, bytes: Uint8List.fromList(utf8.encode(text)));

/// The XHTML of [epub] in archive order, which is reading order.
String epubText(Uint8List epub) => ZipDecoder()
    .decodeBytes(epub)
    .files
    .where((f) => f.name.startsWith('OEBPS/text/'))
    .map((f) => utf8.decode(f.content as List<int>))
    .join();

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

  group('TXT import', () {
    late MemoryEpubStorage storage;
    late RecordingRealtime realtime;
    late FakeRoomService rooms;
    late ProviderContainer container;

    setUp(() async {
      storage = MemoryEpubStorage();
      realtime = RecordingRealtime();
      rooms = FakeRoomService();
      container = ProviderContainer(
        overrides: [
          epubStorageProvider.overrideWithValue(storage),
          libraryServiceProvider.overrideWithValue(SlowLibrary()),
          realtimeServiceProvider.overrideWithValue(realtime),
          roomProvider.overrideWith((ref) => RoomNotifier(rooms)),
        ],
      );
      await container.read(roomProvider.notifier).createRoom('Alice');
    });

    tearDown(() {
      container.dispose();
      storage.dir.deleteSync(recursive: true);
    });

    test('TXT volumes picked together become one book the room reads, '
        'in volume order', () async {
      final books = container.read(bookProvider.notifier);
      TxtImportDraft? shown;

      await books.shareTxtBooks(
        [
          txt('雨夜_卷二.txt', '第二章 天亮\n　　院子里的树倒了。\n'),
          txt('雨夜_卷一.txt', '作者：林某\n第一章 雨夜\n　　他一个人走在路上。\n'),
        ],
        confirm: (draft) async {
          shown = draft;
          return TxtBookRequest(
            title: draft.title,
            author: draft.author,
            parts: [
              for (var i = 0; i < draft.sources.length; i++)
                TxtPart(draft.sources[i], draft.analyses[i].encoding),
            ],
          );
        },
      );

      expect(shown!.sources.map((s) => s.fileName), ['雨夜_卷一.txt', '雨夜_卷二.txt']);
      expect(shown!.title, '雨夜');
      expect(shown!.author, '林某');

      final state = container.read(bookProvider);
      expect(state.error, isNull);
      expect(state.isLoading, isFalse);
      expect(state.currentBook!.title, '雨夜');
      expect(state.currentBook!.author, '林某');

      // The room's book is the converted EPUB, announced like any other.
      final epub = storage.saved.values.single;
      expect(
        container.read(roomProvider).currentRoom?.currentBookHash,
        sha256.convert(epub).toString(),
      );
      expect(realtime.events, contains('book_shared'));
      final text = epubText(epub);
      expect(text.indexOf('他一个人走在路上'), lessThan(text.indexOf('院子里的树倒了')));
    });

    test(
      'backing out of the TXT sheet shares nothing and frees Share',
      () async {
        final books = container.read(bookProvider.notifier);

        await books.shareTxtBooks([
          txt('雨夜.txt', '第一章\n　　雨。\n'),
        ], confirm: (_) async => null);

        final state = container.read(bookProvider);
        expect(state.isLoading, isFalse);
        expect(state.error, isNull);
        expect(state.currentBook, isNull);
        expect(
          container.read(roomProvider).currentRoom?.currentBookHash,
          isNull,
        );
        expect(storage.saved, isEmpty);
      },
    );

    test('a book someone shares while the TXT sheet is open does not cancel '
        'the import the reader then confirms', () async {
      final books = container.read(bookProvider.notifier);
      final bobHash = sha256.convert([7, 7, 7]).toString();

      await books.shareTxtBooks(
        [txt('雨夜.txt', '第一章\n　　雨。\n')],
        confirm: (draft) async {
          await books.prepareForSharedBook(bobHash);
          return TxtBookRequest(
            title: 'Rain',
            parts: [TxtPart(draft.sources.single, TxtEncoding.utf8)],
          );
        },
      );

      final state = container.read(bookProvider);
      expect(state.error, isNull);
      expect(state.currentBook!.title, 'Rain');
      expect(
        container.read(roomProvider).currentRoom?.currentBookHash,
        sha256.convert(storage.saved.values.single).toString(),
      );
    });

    test('TXT files over the size limit are refused before anything is '
        'decoded', () async {
      final books = container.read(bookProvider.notifier);
      var asked = false;

      await books.shareTxtBooks(
        [
          TxtSource(
            fileName: 'huge.txt',
            bytes: Uint8List(AppConstants.maxFileSize + 1),
          ),
        ],
        confirm: (_) async {
          asked = true;
          return null;
        },
      );

      final state = container.read(bookProvider);
      expect(asked, isFalse);
      expect(state.isLoading, isFalse);
      expect(
        state.error,
        'This file is 40.0 MB. A book can be made of at '
        'most 40.0 MB of text.',
      );
    });
  });

  test('a pick is one EPUB or any number of TXT files', () {
    expect(pickedBookKind(['a.epub']), PickedBookKind.epub);
    expect(pickedBookKind(['a.TXT']), PickedBookKind.txt);
    expect(pickedBookKind(['a.txt', 'b.txt']), PickedBookKind.txt);
    expect(pickedBookKind(['a.epub', 'b.txt']), PickedBookKind.mixed);
    expect(pickedBookKind(['a.epub', 'b.epub']), PickedBookKind.mixed);
    expect(pickedBookKind(['a.pdf']), PickedBookKind.mixed);
  });
}
