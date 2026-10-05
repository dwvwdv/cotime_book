import 'dart:io';
import 'dart:typed_data';

import 'package:cotime_book/config/app_constants.dart';
import 'package:cotime_book/models/book_metadata.dart';
import 'package:cotime_book/models/library_book.dart';
import 'package:cotime_book/providers/book_provider.dart';
import 'package:cotime_book/services/library_service.dart';
import 'package:cotime_book/widgets/share_book_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show FileObject;

FileObject object(String name, {String? id = 'id', int? size}) => FileObject(
  name: name,
  bucketId: AppConstants.libraryBucket,
  owner: null,
  id: id,
  updatedAt: null,
  createdAt: null,
  lastAccessedAt: null,
  metadata: size == null ? null : {'size': size},
  buckets: null,
);

class FakeLibrary implements LibraryService {
  final List<Future<List<LibraryBook>> Function()> answers;
  int listCalls = 0;

  FakeLibrary(this.answers);

  @override
  Future<List<LibraryBook>> listBooks() => answers[listCalls++]();

  @override
  Future<Uint8List> download(String path) async => Uint8List(0);
}

void main() {
  group('the library shows', () {
    test('only EPUB files, sorted by title', () {
      final books = libraryBooksFromObjects([
        object('the_time_machine.epub', size: 300 * 1024),
        object('a-folder', id: null),
        object('.emptyFolderPlaceholder'),
        object('notes.txt'),
        object('Alice in Wonderland.EPUB', size: 2 * 1024 * 1024),
      ]);

      expect(books.map((book) => book.title), [
        'Alice in Wonderland',
        'the time machine',
      ]);
      expect(books.first.sizeFormatted, '2.0 MB');
      expect(books.last.sizeFormatted, '300 KB');
    });

    test('no book larger than every device accepts', () {
      final books = libraryBooksFromObjects([
        object('fits.epub', size: AppConstants.maxFileSize),
        object('too-big.epub', size: AppConstants.maxFileSize + 1),
      ]);

      expect(books.map((book) => book.fileName), ['fits.epub']);
    });
  });

  test('a shared book says where it is in the library', () {
    const metadata = BookMetadata(
      id: 'h',
      title: 'Alice',
      author: 'Unknown',
      fileName: 'Alice.epub',
      fileSizeBytes: 1,
      fileHash: 'h',
      libraryPath: 'Alice.epub',
    );

    expect(BookMetadata.fromJson(metadata.toJson()).libraryPath, 'Alice.epub');
    expect(
      const BookMetadata(
        id: 'h',
        title: 'Mine',
        author: 'Unknown',
        fileName: 'Mine.epub',
        fileSizeBytes: 1,
        fileHash: 'h',
      ).toJson().containsKey('library_path'),
      isFalse,
    );
  });

  test('a library path from the room must be a plain object name', () {
    expect(isPlainLibraryPath('Alice.epub'), isTrue);
    expect(isPlainLibraryPath('classics/Alice.epub'), isTrue);
    expect(isPlainLibraryPath(''), isFalse);
    expect(isPlainLibraryPath('/Alice.epub'), isFalse);
    expect(isPlainLibraryPath('../other-bucket/x.epub'), isFalse);
    expect(isPlainLibraryPath('classics//Alice.epub'), isFalse);
    expect(isPlainLibraryPath(r'..\x.epub'), isFalse);
  });

  test('the library bucket matches the app limit', () {
    // A bucket that accepts bigger files would list books every device
    // refuses; a smaller one would refuse books the app can share.
    final migration = File(
      'supabase/migrations/20261004200000_public_library_bucket.sql',
    ).readAsStringSync();

    expect(migration, contains("'${AppConstants.libraryBucket}'"));
    expect(AppConstants.maxFileSize, 40 * 1024 * 1024);
    expect(migration, contains('40 * 1024 * 1024'));
  });

  group('the share sheet', () {
    /// Opens the sheet; the returned getter reads what it popped with.
    Future<ShareBookChoice? Function()> openSheet(
      WidgetTester tester,
      LibraryService library,
    ) async {
      ShareBookChoice? choice;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  choice = await showModalBottomSheet<ShareBookChoice>(
                    context: context,
                    builder: (_) => ShareBookSheet(library: library),
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      return () => choice;
    }

    testWidgets('shares the library book that is tapped', (tester) async {
      final choice = await openSheet(
        tester,
        FakeLibrary([
          () async => const [
            LibraryBook(path: 'Alice in Wonderland.epub', sizeBytes: 1024),
            LibraryBook(path: 'The_Time_Machine.epub'),
          ],
        ]),
      );

      expect(find.text('2 books'), findsOneWidget);
      await tester.tap(find.text('The Time Machine'));
      await tester.pumpAndSettle();

      expect(choice(), isA<ShareFromLibrary>());
      expect(
        (choice()! as ShareFromLibrary).book.path,
        'The_Time_Machine.epub',
      );
    });

    testWidgets('still offers a file from the device', (tester) async {
      await openSheet(tester, FakeLibrary([() async => const []]));

      expect(find.text('The library is empty for now.'), findsOneWidget);
      expect(find.text('Choose a File on This Device'), findsOneWidget);
    });

    testWidgets('a library that cannot be reached can be tried again', (
      tester,
    ) async {
      final library = FakeLibrary([
        () async => throw Exception('offline'),
        () async => const [LibraryBook(path: 'Alice.epub')],
      ]);
      await openSheet(tester, library);

      expect(find.text('The library could not be opened.'), findsOneWidget);
      await tester.tap(find.text('Try Again'));
      await tester.pumpAndSettle();

      expect(find.text('Alice'), findsOneWidget);
      expect(library.listCalls, 2);
    });
  });
}
