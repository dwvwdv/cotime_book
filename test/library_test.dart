import 'dart:io';
import 'dart:typed_data';

import 'package:cotime_book/config/app_constants.dart';
import 'package:cotime_book/models/book_metadata.dart';
import 'package:cotime_book/models/library_book.dart';
import 'package:cotime_book/providers/book_provider.dart';
import 'package:cotime_book/services/library_service.dart';
import 'package:cotime_book/widgets/library_browser.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> row(
  String path, {
  int? size,
  String? title,
  String? author,
  String? language,
  String? category,
}) => {
  'path': path,
  'size_bytes': size,
  'title': title,
  'author': author,
  'language': language,
  'category': category,
};

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
    test('catalogued books by their catalog title, the rest by file name', () {
      final books = libraryBooksFromRows([
        row('the_time_machine.epub', size: 300 * 1024),
        row(
          'classics/hongloumeng.epub',
          size: 2 * 1024 * 1024,
          title: '紅樓夢',
          author: '曹雪芹',
          language: 'zh-Hant',
          category: 'Classics',
        ),
        row('Alice in Wonderland.EPUB', title: '  ', author: ''),
      ]);

      expect(books.map((book) => book.title), [
        'Alice in Wonderland',
        'the time machine',
        '紅樓夢',
      ]);
      // A blank catalog field is no field, not an empty label.
      expect(books.first.author, isNull);
      expect(books.last.author, '曹雪芹');
      expect(books.last.languageName, 'Chinese (Traditional)');
      expect(books.last.fileName, 'hongloumeng.epub');
      expect(books.last.sizeFormatted, '2.0 MB');
      expect(books[1].sizeFormatted, '300 KB');
    });

    test('no book larger than every device accepts', () {
      final books = libraryBooksFromRows([
        row('fits.epub', size: AppConstants.maxFileSize),
        row('too-big.epub', size: AppConstants.maxFileSize + 1),
      ]);

      expect(books.map((book) => book.fileName), ['fits.epub']);
    });
  });

  group('searching the library', () {
    const dream = LibraryBook(
      path: 'hongloumeng.epub',
      title: '紅樓夢',
      author: '曹雪芹',
      language: 'zh-Hant',
      category: 'Classics',
    );
    const alice = LibraryBook(
      path: 'alice.epub',
      title: "Alice's Adventures in Wonderland",
      author: 'Lewis Carroll',
      language: 'en',
      category: 'Children',
    );
    const machine = LibraryBook(
      path: 'The_Time_Machine.epub',
      language: 'en-GB',
      category: 'Science Fiction',
    );
    const books = [dream, alice, machine];

    test('by title, author or file name, in any order and case', () {
      expect(const LibraryFilter(query: '樓夢').apply(books), [dream]);
      expect(const LibraryFilter(query: 'carroll').apply(books), [alice]);
      expect(const LibraryFilter(query: 'wonderland LEWIS').apply(books), [
        alice,
      ]);
      expect(const LibraryFilter(query: 'time machine').apply(books), [
        machine,
      ]);
      expect(const LibraryFilter(query: 'hongloumeng').apply(books), [dream]);
      expect(const LibraryFilter(query: 'alice dickens').apply(books), isEmpty);
      expect(const LibraryFilter(query: '   ').apply(books), books);
    });

    test('by category and language together with the words', () {
      expect(const LibraryFilter(category: 'Classics').apply(books), [dream]);
      expect(const LibraryFilter(language: 'English').apply(books), [
        alice,
        machine,
      ]);
      expect(
        const LibraryFilter(
          query: 'time',
          category: 'Children',
          language: 'English',
        ).apply(books),
        isEmpty,
      );
    });

    test('offers each category and language once, by name', () {
      expect(libraryCategories(books), [
        'Children',
        'Classics',
        'Science Fiction',
      ]);
      // en and en-GB are one language to a reader.
      expect(libraryLanguages(books), ['Chinese (Traditional)', 'English']);
      expect(libraryCategories(const [LibraryBook(path: 'x.epub')]), isEmpty);
    });

    test('names the language tags the catalog is likely to use', () {
      expect(describeLanguage('zh-TW'), 'Chinese (Traditional)');
      expect(describeLanguage('zh_Hant_HK'), 'Chinese (Traditional)');
      expect(describeLanguage('zh-CN'), 'Chinese (Simplified)');
      expect(describeLanguage('zh'), 'Chinese');
      expect(describeLanguage('JA'), 'Japanese');
      expect(describeLanguage('tlh'), 'tlh');
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

  test('the catalog lists the same bucket the app downloads from', () {
    final migration = File(
      'supabase/migrations/20261005120000_library_catalog.sql',
    ).readAsStringSync();

    expect(migration, contains("bucket_id = '${AppConstants.libraryBucket}'"));
  });

  group('the library browser', () {
    /// Opens the browser; the returned getter reads the book it resolved with.
    Future<LibraryBook? Function()> openBrowser(
      WidgetTester tester,
      LibraryService library,
    ) async {
      LibraryBook? picked;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  picked = await showLibraryBrowser(
                    context: context,
                    library: library,
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
      return () => picked;
    }

    /// A filter choice, not a book whose details read the same.
    Finder choice(String label) => find.descendant(
      of: find.byWidgetPredicate(
        (widget) =>
            widget is SingleChildScrollView &&
            widget.scrollDirection == Axis.horizontal,
      ),
      matching: find.text(label),
    );

    /// Scrolls the filter row to [label] first, as a reader would.
    Future<void> tapChoice(WidgetTester tester, String label) async {
      await tester.ensureVisible(choice(label));
      await tester.pump();
      await tester.tap(choice(label));
    }

    const catalog = [
      LibraryBook(
        path: 'hongloumeng.epub',
        title: '紅樓夢',
        author: '曹雪芹',
        language: 'zh-Hant',
        category: 'Classics',
      ),
      LibraryBook(
        path: 'alice.epub',
        sizeBytes: 1024,
        title: "Alice's Adventures in Wonderland",
        author: 'Lewis Carroll',
        language: 'en',
        category: 'Children',
      ),
      LibraryBook(path: 'The_Time_Machine.epub', language: 'en'),
    ];

    testWidgets('picks the book that is tapped', (tester) async {
      final picked = await openBrowser(
        tester,
        FakeLibrary([() async => catalog]),
      );

      expect(find.text('3 books'), findsOneWidget);
      expect(find.text('Lewis Carroll · Children · English · 1 KB'), findsOne);
      await tester.tap(find.text('The Time Machine'));
      await tester.pumpAndSettle();

      expect(picked()?.path, 'The_Time_Machine.epub');
    });

    testWidgets('finds a book by its name', (tester) async {
      await openBrowser(tester, FakeLibrary([() async => catalog]));

      await tester.enterText(find.byType(TextField), '紅樓');
      await tester.pump();

      expect(find.text('紅樓夢'), findsOneWidget);
      expect(find.text('The Time Machine'), findsNothing);
      expect(find.text('1 of 3 books'), findsOneWidget);
    });

    testWidgets('narrows by category and by language', (tester) async {
      await openBrowser(tester, FakeLibrary([() async => catalog]));

      await tapChoice(tester, 'English');
      await tester.pump();
      expect(find.text('紅樓夢'), findsNothing);
      expect(find.text('The Time Machine'), findsOneWidget);
      expect(find.text("Alice's Adventures in Wonderland"), findsOneWidget);

      await tapChoice(tester, 'Children');
      await tester.pump();
      expect(find.text('The Time Machine'), findsNothing);
      expect(find.text("Alice's Adventures in Wonderland"), findsOneWidget);

      // Tapping the chosen category again lets go of it.
      await tapChoice(tester, 'Children');
      await tester.pump();
      expect(find.text('The Time Machine'), findsOneWidget);
    });

    testWidgets('a search with no result can be cleared in one tap', (
      tester,
    ) async {
      await openBrowser(tester, FakeLibrary([() async => catalog]));

      await tapChoice(tester, 'Classics');
      await tester.enterText(find.byType(TextField), 'carroll');
      await tester.pump();
      expect(find.text('No books match.'), findsOneWidget);

      await tester.tap(find.text('Clear Search and Filters'));
      await tester.pump();
      expect(find.text('3 books'), findsOneWidget);
      expect(find.text('紅樓夢'), findsOneWidget);
    });

    testWidgets('an uncatalogued library offers no empty filters', (
      tester,
    ) async {
      await openBrowser(
        tester,
        FakeLibrary([
          () async => const [LibraryBook(path: 'Alice.epub')],
        ]),
      );

      expect(find.text('Alice'), findsOneWidget);
      expect(find.text('CATEGORY'), findsNothing);
      expect(find.text('LANGUAGE'), findsNothing);
    });

    testWidgets('says when the library is empty', (tester) async {
      await openBrowser(tester, FakeLibrary([() async => const []]));

      expect(find.text('The library is empty for now.'), findsOneWidget);
    });

    testWidgets('a library that cannot be reached can be tried again', (
      tester,
    ) async {
      final library = FakeLibrary([
        () async => throw Exception('offline'),
        () async => const [LibraryBook(path: 'Alice.epub')],
      ]);
      await openBrowser(tester, library);

      expect(find.text('The library could not be opened.'), findsOneWidget);
      await tester.tap(find.text('Try Again'));
      await tester.pumpAndSettle();

      expect(find.text('Alice'), findsOneWidget);
      expect(library.listCalls, 2);
    });
  });
}
